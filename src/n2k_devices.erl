-module(n2k_devices).

-export([
    get_devices/2,
    print_devices/2,
    merge_device_information/3
]).

%% send isoRequest:pgn = 60928 - to 255
%% send 59904 isoRequest:pgn = 126996 - to each device
%% send 59904 isoRequest:pgn = 126998 - to each device

-record(get_devices, {
    tr,
    st = collect_devices,
    devices = [] :: [integer()],
    pgnLists = [],
    isoAddressClaims = [],
    productInformations = [],
    configInformations = []
}).

-spec get_devices(n2k_transport:transport(), TimeoutMs :: integer()) ->
    {ok, [
        {DeviceId :: integer(), {
            IsoAddressClaim :: n2k:message() | undefined,
            ProductInformation :: n2k:message() | undefined,
            ConfigInformation :: n2k:message() | undefined
        }}
    ]}
    | {error, term()}.
get_devices(Transport, TimeoutMs) ->
    S0 = #get_devices{tr = Transport},

    %% Send first request for 60928 to all devices
    ok = n2k_transport:send(Transport, n2k:isoRequest(60928, 255)),
    erlang:send_after(1000, self(), step0),

    %% Set timer to terminate collection of responses
    erlang:send_after(TimeoutMs, self(), stop),

    %% Collect responses
    PGNs = [60928, 126464, 126996, 126998],
    S1 = n2k_transport:recv(Transport, {message, PGNs, frame}, fun get_devices_handler/2, S0),
    A = lists:keysort(1, S1#get_devices.isoAddressClaims),
    B = lists:keysort(1, S1#get_devices.productInformations),
    C = lists:keysort(1, S1#get_devices.configInformations),
    {ok, merge_device_information(A, B, C)}.

get_devices_handler({frame, Frame}, S) when S#get_devices.st == collect_devices ->
    %% We received a frame that was not part of the messages we look for.
    %% Add the device to the devices list
    {_Time, {_Pri, _PGN, Src, _Dst}, _} = Frame,
    Devices = S#get_devices.devices,
    case lists:member(Src, Devices) of
        false ->
            S#get_devices{devices = [Src | Devices]};
        true ->
            S
    end;
get_devices_handler({frame, _Frame}, S) ->
    S;
get_devices_handler({message, Msg}, S0) ->
    {_Time, {_Pri, PGN, Src, _Dst}, _} = Msg,
    S1 =
        if
            S0#get_devices.st == collect_devices ->
                Devices = S0#get_devices.devices,
                case lists:member(Src, Devices) of
                    false ->
                        S0#get_devices{devices = [Src | Devices]};
                    true ->
                        S0
                end;
            true ->
                S0
        end,
    if
        %% isoAddressClaim
        PGN == 60928 ->
            L = maybe_add(Src, Msg, S1#get_devices.isoAddressClaims),
            S1#get_devices{isoAddressClaims = L};
        %% pgnListTransmitAndReceive
        PGN == 126464 ->
            {_, _, {_, Fields}} = Msg,
            case lists:member({functionCode, 0}, Fields) of
                true ->
                    L = maybe_add(Src, [P || {pgn, P} <- Fields], S1#get_devices.pgnLists),
                    S1#get_devices{pgnLists = L};
                false ->
                    S1
            end;
        %% productInformation
        PGN == 126996 ->
            L = maybe_add(Src, Msg, S1#get_devices.productInformations),
            S1#get_devices{productInformations = L};
        %% configInformation
        PGN == 126998 ->
            L = maybe_add(Src, Msg, S1#get_devices.configInformations),
            S1#get_devices{configInformations = L}
    end;
get_devices_handler(step0, S) ->
    %% Send request for 60928 to all devices again
    #get_devices{tr = Tr} = S,
    ok = n2k_transport:send(Tr, n2k:isoRequest(60928, 255)),
    timer:sleep(100),
    erlang:send_after(1000, self(), {step1, 1}),
    S;
get_devices_handler({step1, N}, S) ->
    %% Send request for 60928 to individual devices that didn't reply
    #get_devices{devices = Devices0, tr = Tr, isoAddressClaims = IAs} = S,
    case Devices0 -- [Src || {Src, _} <- IAs] of
        Devices when Devices /= [], N =< 5 ->
            send_iso_request_to_each_device(60928, Devices, Tr, {step1, N + 1});
        _ ->
            self() ! {step2, 1}
    end,
    S#get_devices{st = get_info};
get_devices_handler({step2, N}, S) ->
    %% Send request for 126464 untill all have answered
    #get_devices{devices = Devices0, tr = Tr, pgnLists = PLs} = S,
    Devices1 = filter_pgn_list(Devices0, S#get_devices.isoAddressClaims),
    case Devices1 -- [Src || {Src, _} <- PLs] of
        Devices when Devices /= [], N =< 10 ->
            send_iso_request_to_each_device(126464, Devices, Tr, {step2, N + 1});
        _ ->
            self() ! {step3, 1}
    end,
    S#get_devices{st = get_info};
get_devices_handler({step3, N}, S) ->
    %% Send request for 126996 untill all have answered
    #get_devices{
        devices = Devices0,
        tr = Tr,
        pgnLists = PLs,
        productInformations = PIs
    } = S,
    Devices1 = Devices0 -- [Src || {Src, _} <- PIs],
    case filter_devices(126996, Devices1, PLs) of
        Devices when Devices /= [], N =< 10 ->
            send_iso_request_to_each_device(126996, Devices, Tr, {step3, N + 1});
        _ ->
            self() ! {step4, 1}
    end,
    S;
get_devices_handler({step4, N}, S) ->
    %% Send request for 126998 untill all have answered
    %% Some devices claim they support 126998 but actually doesn't (!)
    #get_devices{
        devices = Devices0,
        tr = Tr,
        pgnLists = PLs,
        configInformations = CIs
    } = S,
    ok = n2k_transport:send(Tr, n2k:isoRequest(126998, 255)),
    Devices1 = Devices0 -- [Src || {Src, _} <- CIs],
    case filter_devices(126998, Devices1, PLs) of
        Devices when Devices /= [], N =< 10 ->
            send_iso_request_to_each_device(126998, Devices, Tr, {step4, N + 1});
        _ ->
            self() ! step5
    end,
    S;
get_devices_handler(step5, S) ->
    {done, S};
get_devices_handler(stop, S) ->
    {done, S}.

%% Yacht Devices YDWG-02 doesn't reply to 126464 pgnListTransmitAndReceive.
%% This is an optimization to avoid timing out on this device.
filter_pgn_list(Devices, IsoAddressClaims) ->
    lists:filter(
        fun(Src) ->
            case lists:keyfind(Src, 1, IsoAddressClaims) of
                {Src, {_Time, _, {isoAddressClaim, Fields}}} ->
                    [
                        _UniqueNumber,
                        {manufacturerCode, Code},
                        _DeviceInstanceLower,
                        _DeviceInstanceUpper,
                        {deviceFunction, Function},
                        {deviceClass, Class}
                        | _
                    ] = Fields,
                    if
                        Code == 717,
                        Function == 25,
                        Class == 136 ->
                            false;
                        true ->
                            true
                    end;
                false ->
                    %% This means we haven't received a reply to 60928 from this device...
                    false
            end
        end,
        Devices
    ).

%% Return all devices in `Devices` that claim they support `PGN`.
filter_devices(PGN, Devices, PLs) ->
    lists:filter(
        fun(Src) ->
            case lists:keysearch(Src, 1, PLs) of
                {value, {_, PGNs}} ->
                    lists:member(PGN, PGNs);
                false ->
                    false
            end
        end,
        Devices
    ).

send_iso_request_to_each_device(PGN, Devices, Tr, Next) ->
    %% FIXME: add verbose flag?
    %io:format(standard_error, "Req ~p from ~p\n", [PGN, lists:sort(Devices)]),
    Collector = self(),
    spawn_link(
        fun() ->
            lists:foreach(
                fun(Dst) ->
                    ok = n2k_transport:send(Tr, n2k:isoRequest(PGN, Dst)),
                    timer:sleep(100),
                    ok
                end,
                Devices
            ),
            Collector ! Next
        end
    ).

maybe_add(Src, Msg, L) ->
    case lists:keymember(Src, 1, L) of
        false ->
            [{Src, Msg} | L];
        true ->
            L
    end.

merge_device_information(LA, LB, LC) ->
    merge0(
        [{Src, {A, undefined, undefined}} || {Src, A} <- LA],
        merge0(
            [{Src, {undefined, B, undefined}} || {Src, B} <- LB],
            [{Src, {undefined, undefined, C}} || {Src, C} <- LC]
        )
    ).

merge0([{Src, X} | TX], [{Src, Y} | TY]) ->
    [{Src, merge_tup(X, Y)} | merge0(TX, TY)];
merge0([{SrcX, _} = HX | TX], [{SrcY, _} | _] = LY) when SrcX < SrcY ->
    [HX | merge0(TX, LY)];
merge0(LX, [HY | TY]) ->
    [HY | merge0(LX, TY)];
merge0([], LY) ->
    LY;
merge0(LX, []) ->
    LX.

%% The first tuple has 1 non-undefined
merge_tup({undefined, BX, undefined}, {AY, _BY, CY}) ->
    {AY, BX, CY};
merge_tup({AX, undefined, undefined}, {_AY, BY, CY}) ->
    {AX, BY, CY}.

-define(ISOADDRESSCLAIM_HEADER, " ~-15s ~-40s").
-define(PRODUCTINFORMATION_HEADER, " ~-15s ~-15s ~-8s ~-3s").
-define(CONFIGINFORMATION_HEADER, " ~-15s ~-15s ~-15s").

-spec print_devices(
    fun(),
    [
        {DeviceId :: integer(), {
            IsoAddressClaim :: n2k:message() | undefined,
            ProductInformation :: n2k:message() | undefined,
            ConfigInformation :: n2k:message() | undefined
        }}
    ]
) ->
    ok.
print_devices(WriteF, Res) ->
    Hdr = [
        "src",
        "manufacturer",
        "function",
        "model",
        "product code",
        "software vsn",
        "nmea2000",
        "len",
        "descr1",
        "descr2",
        "info"
    ],
    Rows = [
        Hdr
        | lists:map(
            fun({Src, {A, B, C}}) ->
                {A0, A1} = pi(A),
                {B0, B1, B2, B3, B4} = pp(B),
                {C0, C1, C2} = pc(C),
                [Src, A0, A1, B0, B1, B2, B3, B4, C0, C1, C2]
            end,
            Res
        )
    ],
    R = #{align => right},
    L = #{align => left},
    Cols = [R, L, L, L, L, L, R, L, L, L],
    WriteF("\n"),
    WriteF(
        mtab:format(Rows, #{
            header_fmt => titlecase,
            header => first_row,
            style => presto,
            cols => Cols
        })
    ),
    WriteF("\n").

%fmt_isoAddressClaim({_Time, _, {isoAddressClaim, Fields}}) ->
pi({_Time, _, {isoAddressClaim, Fields}}) ->
    [
        _UniqueNumber,
        {manufacturerCode, Code},
        _DeviceInstanceLower,
        _DeviceInstanceUpper,
        {deviceFunction, Function},
        {deviceClass, Class}
        | _
    ] = Fields,
    {
        get_isoAddressClaim_enum(manufacturerCode, Code),
        get_isoAddressClaim_enum(deviceFunction, {Class, Function})
    };
pi(undefined) ->
    {"", ""}.

%fmt_productInformation({_Time, _, {productInformation, Fields}}) ->
pp({_Time, _, {productInformation, Fields}}) ->
    [
        {nmea2000Version, Nmea2000Version},
        {productCode, ProductCode},
        {modelId, ModelId},
        {softwareVersionCode, SoftwareVersionCode},
        {modelVersion, _ModelVersion},
        {modelSerialCode, _ModelSerialCode},
        {certificationLevel, _CertificationLevel},
        {loadEquivalency, LoadEquivalency}
        | _
    ] = Fields,
    {ModelId, ProductCode, SoftwareVersionCode, io_lib:format("~.3f", [Nmea2000Version * 0.001]),
        LoadEquivalency};
pp(undefined) ->
    {"", "", "", "", ""}.

% fmt_configInformation({_Time, _, {configurationInformation, Fields}}) ->
pc({_Time, _, {configurationInformation, Fields}}) ->
    [
        {installationDescription1, InstallationDescription1},
        {installationDescription2, InstallationDescription2},
        {manufacturerInformation, ManufacturerInformation}
        | _
    ] = Fields,
    {binary_to_list(InstallationDescription1), InstallationDescription2, ManufacturerInformation};
pc(undefined) ->
    {"", "", ""}.

get_isoAddressClaim_enum(Field, Val) ->
    Enums =
        case n2k_pgn:type_info(isoAddressClaim, Field) of
            {enums, Enums0} ->
                Enums0;
            {enums, _, Enums0} ->
                Enums0
        end,
    case lists:keyfind(Val, 2, Enums) of
        {Str, _} ->
            Str;
        _ when is_integer(Val) ->
            integer_to_list(Val);
        _ ->
            {Class, Function} = Val,
            {enums, ClassEnums} =
                n2k_pgn:type_info(isoAddressClaim, deviceClass),
            ClassStr =
                case lists:keyfind(Class, 2, ClassEnums) of
                    {Str, _} ->
                        Str;
                    _ ->
                        integer_to_list(Class)
                end,
            [ClassStr, $/, integer_to_list(Function)]
    end.
