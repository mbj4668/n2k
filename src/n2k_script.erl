%%% Implementation of the `n2k` command line tool.
%%%
%%% Reads 'raw', 'csv', 'dat' and 'can' files, and converts
%%% to 'csv' or pretty text.
-module(n2k_script).
-export([main/1]).
-export([parse_expr/1]).

-define(CNT_MESSAGES, 1).
-define(CNT_FAST_PACKET_ERRORS, 2).
-define(CNT_SIZE, 2).

main(Args) ->
    eclip:parse(Args, spec(), #{}).

spec() ->
    #{require_cmd => true,
      cmds =>
          [cmd_convert(),
           cmd_request()
          ]
     }.

cmd_convert() ->
    #{cmd => "convert",
      help => {doc,
               [{p, "Convert or pretty print INFILE with NMEA 2000 frames"
                    " or messages to some other format."},
                {dl, "Supported input formats are:",
                 [{"csv", "CANBOAT's PLAIN format"}
                  , {"raw", "Yacht Devices' RAW format"}
                  , {"dat", "Yacht Devices' DAT format"}
                  , {"can", "Yacht Devices' CAN format"}
                 ]},
                {p, "By default, the input format is guessed from the input"
                    " file contents."},
                {dl, "Supported output formats are:",
                 [{"pretty", "Human readable"}
                  , {"csv", "CANBOAT's PLAIN format"}
                  , {"devices", "Print product and software information"
                                " about devices found in the input file"}
                  , {"errors", "Print errors"}]},
                {p, "The syntax of a match expression is a boolean expression"
                    " of tests, where each test is 'pgn INT', 'src INT' or"
                    " 'dst INT'.  For example"},
                {pre, "  pgn 59904 and (src 81 or dst 81)"}
               ]},
      opts => [#{short => $q, long => "quiet", type => flag},
               #{short => $F, long => "infmt",
                 help => "Format of INFILE",
                 type => {enum, [raw, csv, dat, can]}},
               #{short => $f, long => "outfmt",
                 type => {enum, [csv, pretty, devices, errors]},
                 default => pretty},
               #{short => $P, long => "pretty-strings", type => flag,
                 help => "Try to detect strings in binary data"},
               opt_src(),
               opt_pgn(),
               opt_match(),
               #{short => $o, name => outfile, type => file}],
      args => [#{name => infname, metavar => "INFILE", type => file}],
      cb => fun do_convert/11}.


opt_src() ->
    #{long => "src", metavar => "SrcId", multiple => true,
      type => int,
      help => "Only include messages from the given devices"}.

opt_pgn() ->
    #{long => "pgn", multiple => true, type => int,
      help => "Only include messages with the given pgns"}.

opt_match() ->
    #{short => $m, long => "match", metavar => "Expression",
      type => {custom, fun parse_expr/1},
      help =>
          "Only inlcude messages that match the given expression"}.


do_convert(Env, CmdStack, Quiet, InFmt0, OutFmt, PStr,
           SrcIds, PGNs, Expr, OutFName, InFName) ->
    try
        InFmt =
            case InFmt0 of
                undefined ->
                    case guess_format(InFName) of
                        unknown ->
                            throw([InFName, ": unknown format"]);
                        InFmt1 ->
                            InFmt1
                    end;
                _ ->
                    InFmt0
            end,
        if InFmt == dat andalso OutFmt == csv ->
                throw("Cannot convert dat to csv");
           true ->
                ok
        end,
        {CloseF, WriteF} =
            if OutFName /= undefined ->
                    {ok, OutFd} =
                        file:open(OutFName,
                                  [write, raw, binary, delayed_write]),
                    {fun() -> file:close(OutFd) end,
                     fun(Bin) -> file:write(OutFd, Bin) end};
               true ->
                    {fun() -> ok end,
                     fun(Bin) -> io:put_chars(Bin) end}
            end,
        PrettyF =
            fun(Message) ->
                    Str = n2k:fmt_nmea_message(Message, PStr),
                    WriteF(Str)
            end,
        ETab = ets:new(etab, []),
        Cnts = counters:new(?CNT_SIZE, []),
        {OutF, OutFInitState} =
            case OutFmt of
                csv ->
                    {fun(Frame, _) when element(2, Frame) /= 'service' ->
                             WriteF(n2k_csv:encode_csv(Frame));
                        (_SrvRec, _) ->
                             []
                     end,
                     []};
                pretty when InFmt == dat ->
                    {fun({_Time, 'service', _Data} = SrvRec, _) ->
                             Str = n2k_dat:fmt_service_record(SrvRec),
                             WriteF(Str);
                        ({Time, Id, Data}, _) ->
                             {_Pri, PGN, _Src, _Dst} = Id,
                             Message = {Time, Id, n2k_pgn:decode(PGN, Data)},
                             PrettyF(Message)
                     end,
                     []};
                pretty ->
                    {fun(Frame, State0) when element(2, Frame) /= 'service' ->
                             case n2k:decode_nmea(Frame, State0) of
                                 {true, Message, State1} ->
                                     counters:add(Cnts,
                                                  ?CNT_MESSAGES,
                                                  1),
                                     PrettyF(Message),
                                     State1;
                                 {false, State1} ->
                                     State1;
                                 {error,
                                  {frame_loss, Src, PGN, Order, _PrevIndex},
                                  State1} ->
                                     frame_lost(Src, PGN, Order, ETab, Cnts),
                                     State1;
                                 {error, Error, State1} ->
                                     io:format(standard_error,
                                               n2k:fmt_error(Error), []),
                                     State1
                             end;
                        (SrvRec, State0) when InFmt == can ->
                             Str = n2k_can:fmt_service_record(SrvRec),
                             WriteF(Str),
                             State0
                     end,
                     n2k:decode_nmea_init()};
                devices ->
                    {fun({_, {_, PGN, Src, _}, _} = Frame, {State0, X, Y, Z})
                           when PGN == 60928 orelse
                                PGN == 126996 orelse
                                PGN == 126998 ->
                             case n2k:decode_nmea(Frame, State0) of
                                 {true, Msg, State1} when PGN == 60928 ->
                                     case lists:keymember(Src, 1, X) of
                                         false ->
                                             {State1, [{Src, Msg} | X], Y, Z};
                                         true ->
                                             {State1, X, Y, Z}
                                     end;
                                 {true, Msg, State1} when PGN == 126996 ->
                                     case lists:keymember(Src, 1, Y) of
                                         false ->
                                             {State1, X, [{Src, Msg} | Y], Z};
                                         true ->
                                             {State1, X, Y, Z}
                                     end;
                                 {true, Msg, State1} when PGN == 126998 ->
                                     case lists:keymember(Src, 1, Z) of
                                         false ->
                                             {State1, X, Y, [{Src, Msg} | Z]};
                                         true ->
                                             {State1, X, Y, Z}
                                     end;
                                 {false, State1} ->
                                     {State1, X, Y, Z};
                                 {error, _, State1} ->
                                     {State1, X, Y, Z}
                             end;
                        (eof, {_, X0, Y0, Z0}) ->
                             X = lists:keysort(1, X0),
                             Y = lists:keysort(1, Y0),
                             Z = lists:keysort(1, Z0),
                             fmt_devices(WriteF, X, Y, Z);
                        (_, S) ->
                             S
                     end,
                     {n2k:decode_nmea_init(), [], [], []}};
                errors ->
                    {fun(Frame, State0) when element(2, Frame) /= 'service' ->
                             case n2k:decode_nmea(Frame, State0) of
                                 {true, _Message, State1} ->
                                     counters:add(Cnts,
                                                  ?CNT_MESSAGES,
                                                  1),
                                     State1;
                                 {false, State1} ->
                                     State1;
                                 {error,
                                  {frame_loss, Src, PGN, Order, _PrevIndex},
                                  State1} ->
                                     frame_lost(Src, PGN, Order, ETab, Cnts),
                                     State1;
                                 {error, Error, State1} ->
                                     io:format(standard_error,
                                               n2k:fmt_error(Error), []),
                                     State1
                             end;
                        (_SrvRec, State0) when InFmt == can ->
                             counters:add(Cnts,
                                          ?CNT_MESSAGES,
                                          1),
                             State0
                     end,
                     n2k:decode_nmea_init()}
            end,
        {F, FInitState} =
            if Expr /= undefined ->
                    mk_expr_filter_fun(Expr, OutF, OutFInitState);
               true ->
                    mk_filter_fun(SrcIds, PGNs, OutF, OutFInitState)
            end,
        try
            FEndState =
                case InFmt of
                    raw ->
                        n2k_raw:read_raw_file(InFName, F, FInitState);
                    csv ->
                        n2k_csv:read_csv_file(InFName, F, FInitState);
                    dat ->
                        n2k_dat:read_dat_file(InFName, F, FInitState);
                    can ->
                        n2k_can:read_can_file(InFName, F, FInitState)
                end,
            case OutFmt of
                devices ->
                    %% Note: we call OutF directly here, not F.  This is b/c
                    %% a bug (?) in dialyzer.  And it doesn't matter, since
                    %% OutF for 'devices' performs its own pgn filtering.
                    OutF(eof, FEndState);
                _ ->
                    ok
            end,
            if (not Quiet) andalso (OutFmt == pretty orelse OutFmt == errors) ->
                    Msgs = counters:get(Cnts, ?CNT_MESSAGES),
                    if Msgs > 0 ->
                            FastPacketErrors =
                                counters:get(Cnts, ?CNT_FAST_PACKET_ERRORS),
                            io:format(standard_error,
                                      "Fast packet errors: ~w / ~.4f%\n",
                                      [FastPacketErrors,
                                       FastPacketErrors / Msgs]);
                       true ->
                            ok
                    end;
               true ->
                    ok
            end
        after
            CloseF()
        end
    catch
        throw:Reason ->
            io:format(standard_error, "** Error: ~s\n\n", [Reason]),
            eclip:print_help(standard_io, Env, CmdStack),
            halt(1);
        _:terminated ->
            halt(1);
        _:_Error:StackTrace ->
            IsEpipe =
                case StackTrace of
                    [{_M, _F, _A, Extra} | _] ->
                        case lists:keysearch(error_info, 1, Extra) of
                            {value, {_, #{cause := {device, epipe}}}} ->
                                true;
                            _ ->
                                false
                        end;
                    _ ->
                        false
                end,
            if not IsEpipe ->
                    io:format(standard_error, "** ~p\n  ~p\n",
                              [_Error, StackTrace]),
                    halt(1);
               true ->
                    halt(0)
            end
    end.

cmd_request() ->
    #{cmd => "request",
      help => {doc,
               [{p, "Interact with the NMEA 2000 network over TCP or UDP."}]},
      opts => [#{long => "protocol",
                 type => {enum, [tcp, udp]}, default => default_gw_proto()},
               #{long => "address", default => default_gw_address(),
                 help => "IP address or hostname of the NMEA 2000 gateway"},
               #{long => "port",
                 type => int, default => 1457,
                 help => "TCP port to connect to, or UDP port to listen to"}],
      required_cmd => true,
      cmds =>
          [cmd_dump(),
           cmd_get_devices()]}.

default_gw_proto() ->
    case os:getenv("N2K_GW_PROTO") of
        false ->
            udp;
        ProtoStr ->
            case ProtoStr of
                "tcp" -> tcp;
                _ -> udp
            end
    end.

default_gw_address() ->
    case os:getenv("N2K_GW_ADDRESS") of
        false ->
            "localhost";
        AddressStr ->
            AddressStr
    end.

-define(CONNECT_TIMEOUT, 5000).
%-define(ACTIVE_COUNT, 100).
-define(ACTIVE_COUNT, true).

-record(req, {
          buf = undefined :: 'undefined' | binary()
        , gw
        , connectf
        , sendf
        , closef
        , sock = undefined :: 'undefined' | inet:socket()
        }).

init_request({_Cmd, Opts}) ->
    #{protocol := Proto, address := Address0, port := Port} = Opts,
    %% FIXME: proper handling of address!
    {ok, Address} = inet:parse_address(Address0),
    Req =
        case Proto of
            udp ->
                ConnectF =
                    fun() ->
                            gen_udp:open(Port,
                                         [binary, {active, ?ACTIVE_COUNT}])
                    end,
                Sendf =
                    fun(Sock, Packet) ->
                            gen_udp:send(Sock, Address, Port, Packet)
                    end,
                CloseF = fun gen_udp:close/1,
                #req{sock = undefined,
                     gw = {Address, Port},
                     connectf = ConnectF,
                     sendf = Sendf,
                     closef = CloseF};
            tcp ->
                ConnectF =
                    fun() ->
                            TcpOpts = [binary,
                                       {active, ?ACTIVE_COUNT},
                                       {packet, line}],
                            gen_tcp:connect(Address, Port, TcpOpts,
                                            ?CONNECT_TIMEOUT)
                    end,
                Sendf = fun gen_tcp:send/2,
                CloseF = fun gen_tcp:close/1,
                #req{sock = undefined,
                     gw = {Address, Port},
                     connectf = ConnectF,
                     sendf = Sendf,
                     closef = CloseF}
        end,
    connect(Req).

connect(#req{connectf = ConnectF} = R) ->
    case ConnectF() of
        {ok, Sock} ->
            {ok, R#req{sock = Sock}};
        {error, Error} ->
            ErrStr =
                case Error of
                    timeout ->
                        "timeout";
                    _ ->
                        inet:format_error(Error)
                end,
            {Address, Port} = R#req.gw,
            io:format(standard_error,
                      "Failed to connect to NMEA gateway ~s:~p: ~s\n",
                      [Address, Port, ErrStr]),
            halt(1)
    end.

loop(R, HandleF, HandleS) ->
    receive
        {udp, _, _, _, Data} ->
            {R1, HandleS1} = handle_data(Data, R, HandleF, HandleS),
            loop(R1, HandleF, HandleS1);
        {tcp, _, Data} ->
            {R1, HandleS1} = handle_data(Data, R, HandleF, HandleS),
            loop(R1, HandleF, HandleS1);
        {udp_passive, Sock} ->
            inet:setopts(Sock, [{active, ?ACTIVE_COUNT}]),
            loop(R, HandleF, HandleS);
        {tcp_passive, Sock} ->
            inet:setopts(Sock, [{active, ?ACTIVE_COUNT}]),
            loop(R, HandleF, HandleS);
        Else ->
            HandleS1 = HandleF(Else, HandleS),
            loop(R, HandleF, HandleS1)
    end.

handle_data(<<>>, R, _, HandleS) ->
    {R, HandleS};
handle_data(Data, #req{buf = Buf} = R, HandleF, HandleS0) ->
    {Buf1, Lines} = lines(Buf, Data),
    HandleS2 =
        lists:foldl(
          fun(Line, HandleS1) ->
                  HandleF(Line, HandleS1)
          end,
          HandleS0,
          Lines),
    {R#req{buf = Buf1}, HandleS2}.

lines(Buf, Data) ->
    case binary:last(Data) of
        $\n when Buf == undefined ->
            %% no need to buffer anything!
            Lines =
                binary:split(Data, <<"\r\n">>, [global, trim_all]),
            {undefined, Lines};
        $\n ->
            %% no need to buffer, but we have buffered data
            [RestLine | Lines] =
                binary:split(Data, <<"\r\n">>, [global, trim_all]),
            {undefined, [<<Buf/binary, RestLine/binary>> | Lines]};
        _ when Buf == undefined ->
            %% we need to buffer
            Lines =
                binary:split(Data, <<"\r\n">>, [global, trim_all]),
            %% the last part of Lines needs to be buffered
            [Buf1 | T] = lists:reverse(Lines),
            {Buf1, lists:reverse(T)};
        _ ->
            %% we need to buffer, and we have buffered data
            [RestLine | Lines] =
                binary:split(Data, <<"\r\n">>, [global, trim_all]),
            [Buf1 | T] = lists:reverse(Lines),
            {Buf1, [<<Buf/binary, RestLine/binary>> | lists:reverse(T)]}
    end.


cmd_dump() ->
    #{cmd => "dump",
      help => {doc,
               [{p, "Listen to NMEA 2000 over TCP or UDP and print matching"
                    " frames or messages."}]},
      opts => [opt_match(),
               #{short => $f, long => "outfmt",
                 type => {enum, [raw, pretty]},
                 default => pretty}],
      cb => fun do_dump/4}.

-record(dump, {
          n2k_state = n2k:decode_nmea_init()
        , outfmt
        , expr
        }).

do_dump(_Env, CmdStack, Expr, OutFmt) ->
    [ReqCmd | _] = CmdStack,
    S = #dump{outfmt = OutFmt, expr = Expr},
    {ok, R} = init_request(ReqCmd),
    loop(R, fun dump_raw_line/2, S).

%% Line is unparsed bytes; one line of RAW format.
dump_raw_line(Line, S) ->
    #dump{n2k_state = N2kState0, outfmt = OutFmt, expr = Expr} = S,
    {Frame, _Dir} = n2k_raw:decode_raw(Line),
    {_Time, {_Pri, _PGN, _Src, _Dst}, _Data} = Frame,
    case
        Expr == undefined orelse eval(Expr, Frame)
    of
        true->
            case OutFmt of
                raw ->
                    io:put_chars([Line, $\n]),
                    S;
                pretty ->
                    N2kState2 =
                        case n2k:decode_nmea(Frame, N2kState0) of
                            {true, Message, N2kState1} ->
                                Str = n2k:fmt_nmea_message(Message, true),
                                io:put_chars(Str),
                                N2kState1;
                            {false, N2kState1} ->
                                N2kState1;
                            {error, _Error, N2kState1} ->
                                %?LOG_DEBUG(fun n2k:fmt_error/1, Error),
                                N2kState1
                        end,
                    S#dump{n2k_state = N2kState2}
            end;
        false ->
            S
    end.

cmd_get_devices() ->
    #{cmd => "get-devices",
      help => {doc,
               [{p, "Request isoAddressClaim, productInformation, and "
                    " configInformation messages "
                    " from all devices and print the result."}]},
      opts => [#{short => $t, long => "timeout",
                 type => {int, [{0, unbounded}]}, default => 20000}],
      cb => fun do_get_devices/3}.

%% send isoRequest:pgn = 60928 - to 255
%% send 59904 isoRequest:pgn = 126996 - to each device
%% send 59904 isoRequest:pgn = 126998 - to each device

-record(get_devices, {
          n2k_state = n2k:decode_nmea_init()
        , st = collect_devices
        , req
        , devices = []
        , pgnLists = []
        , isoAddressClaims = []
        , productInformations = []
        , configInformations = []
        }).

do_get_devices(_Env, CmdStack, Timeout) ->
    [ReqCmd | _] = CmdStack,
    {ok, R} = init_request(ReqCmd),
    S = #get_devices{req = R},

    %% Send first request for 60928 to all devices
    ok = (R#req.sendf)(R#req.sock, isoRequest(60928, 255)),
    erlang:send_after(1000, self(), step0),

    %% Set timer to terminate collection of responses
    erlang:send_after(Timeout, self(), stop),

    %% Collect responses
    loop(R, fun get_devices_raw_line/2, S).

isoRequest(PGN, Dst) ->
    CanId = {_Pri = 4, 59904, _Src = 95, Dst},
    Data = <<PGN:24/little-unsigned>>,
    n2k_raw:encode_raw_frame(CanId, Data).

get_devices_raw_line(Line, S0) when is_binary(Line) ->
    {Frame, _Dir} = n2k_raw:decode_raw(Line),
    {_Time, {_Pri, PGN, Src, _Dst}, _Data} = Frame,
    S1 =
        if S0#get_devices.st == collect_devices ->
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
    if PGN == 60928 orelse PGN == 126464 orelse
       PGN == 126996 orelse PGN == 126998 ->
            case n2k:decode_nmea(Frame, S1#get_devices.n2k_state) of
                {true, Msg, N2kState1} ->
                    S2 = S1#get_devices{n2k_state = N2kState1},
                    if PGN == 60928 ->
                            L = maybe_add(Src, Msg,
                                          S1#get_devices.isoAddressClaims),
                            S2#get_devices{isoAddressClaims = L};
                       PGN == 126464 ->
                            {_, _, {_, Fields}} = Msg,
                            case lists:member({functionCode, 0}, Fields) of
                                true ->
                                    L = maybe_add(Src, [P || {pgn,P} <- Fields],
                                                  S1#get_devices.pgnLists),
                                    S2#get_devices{pgnLists = L};
                                false ->
                                    S2
                            end;
                       PGN == 126996 ->
                            L = maybe_add(Src, Msg,
                                          S1#get_devices.productInformations),
                            S2#get_devices{productInformations = L};
                       PGN == 126998 ->
                            L = maybe_add(Src, Msg,
                                          S1#get_devices.configInformations),
                            S2#get_devices{configInformations = L}
                    end;
                {false, N2kState1} ->
                    S1#get_devices{n2k_state = N2kState1};
                {error, _, N2kState1} ->
                    S1#get_devices{n2k_state = N2kState1}
            end;
       true ->
            S1
    end;
get_devices_raw_line(step0, S) ->
    %% Send request for 60928 to all devices again
    #get_devices{req = R} = S,
    ok = (R#req.sendf)(R#req.sock, isoRequest(60928, 255)),
    timer:sleep(100),
    erlang:send_after(1000, self(), {step1, 1}),
    S;
get_devices_raw_line({step1, N}, S) ->
    %% Send request for 60928 to individual devices that didn't reply
    #get_devices{devices = Devices0, req = R, isoAddressClaims = IAs} = S,
    case Devices0 -- [Src || {Src, _} <- IAs] of
        Devices when Devices /= [], N =< 5 ->
            send_iso_request_to_each_device(60928, Devices, R, {step1, N+1});
        _ ->
            self() ! {step2, 1}
    end,
    S#get_devices{st = get_info};
get_devices_raw_line({step2, N}, S) ->
    %% Send request for 126464 untill all have answered
    #get_devices{devices = Devices0, req = R, pgnLists = PLs} = S,
    Devices1 = filter_pgn_list(Devices0, S#get_devices.isoAddressClaims),
    case Devices1 -- [Src || {Src, _} <- PLs] of
        Devices when Devices /= [], N =< 5 ->
            send_iso_request_to_each_device(126464, Devices, R, {step2, N+1});
        _ ->
            self() ! {step3, 1}
    end,
    S#get_devices{st = get_info};
get_devices_raw_line({step3, N}, S) ->
    %% Send request for 126996 untill all have answered
    #get_devices{devices = Devices0, req = R, pgnLists = PLs,
                 productInformations = PIs} = S,
    Devices1 = Devices0 -- [Src || {Src, _} <- PIs],
    case filter_devices(126996, Devices1, PLs) of
        Devices when Devices /= [], N =< 5 ->
            send_iso_request_to_each_device(126996, Devices, R, {step3, N+1});
        _ ->
            self() ! {step4, 1}
    end,
    S;
get_devices_raw_line({step4, N}, S) ->
    %% Send request for 126998 untill all have answered
    %% Some devices claim they support 126998 but actually doesn't (!)
    #get_devices{devices = Devices0, req = R, pgnLists = PLs,
                 configInformations = CIs} = S,
    ok = (R#req.sendf)(R#req.sock, isoRequest(126998, 255)),
    Devices1 = Devices0 -- [Src || {Src, _} <- CIs],
    case filter_devices(126998, Devices1, PLs) of
        Devices when Devices /= [], N =< 5 ->
            send_iso_request_to_each_device(126998, Devices, R, {step4, N+1});
        _ ->
            self() ! step5
    end,
    S;
get_devices_raw_line(step5, S) ->
    get_device_done(S);
get_devices_raw_line(stop, S) ->
    get_device_done(S).

get_device_done(S) ->
    X = lists:keysort(1, S#get_devices.isoAddressClaims),
    Y = lists:keysort(1, S#get_devices.productInformations),
    Z = lists:keysort(1, S#get_devices.configInformations),
    fmt_devices(fun io:put_chars/1, X, Y, Z),
    halt(0).

%% Yacht Devices YDWG-02 doesn't reply to 126464 pgnListTransmitAndReceive.
%% This is an optimization to avoid timing out on this device.
filter_pgn_list(Devices, IsoAddressClaims) ->
    lists:filter(
      fun(Src) ->
              {Src, {_Time, _, {isoAddressClaim, Fields}}} =
                  lists:keyfind(Src, 1, IsoAddressClaims),
                  [_UniqueNumber,
                   {manufacturerCode, Code},
                   _DeviceInstanceLower,
                   _DeviceInstanceUpper,
                   {deviceFunction, Function},
                   {deviceClass, Class} | _] = Fields,
              if Code == 717,
                 Function == 25,
                 Class == 136 ->
                      false;
                 true ->
                      true
              end
      end, Devices).

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
      end, Devices).

send_iso_request_to_each_device(PGN, Devices, R, Next) ->
    %% FIXME: add verbose flag?
    %io:format(standard_error, "Req ~p from ~p\n", [PGN, lists:sort(Devices)]),
    Collector = self(),
    spawn_link(
      fun() ->
              lists:foreach(
                fun(Dst) ->
                        ok = (R#req.sendf)(R#req.sock, isoRequest(PGN, Dst)),
                        timer:sleep(100),
                        ok
                end, Devices),
              Collector ! Next
      end).

maybe_add(Src, Msg, L) ->
    case lists:keymember(Src, 1, L) of
        false ->
            [{Src, Msg} | L];
        true ->
            L
    end.

guess_format(FName) ->
    {ok, Fd} = file:open(FName, [read, raw, binary, read_ahead]),
    try
        case file:read(Fd, 16) of
            {ok, <<_,_,16#ff,16#ff,16#ff,16#ff,
                   $Y,$D,$V,$R,$\s,$v,$0,$4,_,_>>} ->
                dat;
            {ok, <<_,_,_,_,16#ff,16#ff,16#ff,16#ff,
                   $Y,$D,$V,$R,$\s,$v,$0,$5>>} ->
                can;
            _ ->
                file:position(Fd, 0),
                {ok, Line} = file:read_line(Fd),
                case binary:split(Line, <<" ">>, [global,trim_all]) of
                    [_TimeB, <<_DirCh>>, _CanIdB | _] ->
                        raw;
                    _ ->
                        case binary:split(Line, <<",">>, [global,trim_all]) of
                            [_TimeB, _PriB, _PGNB, _SrcB, _DstB, _SzB | _] ->
                                csv;
                            _ ->
                                unknown
                        end
                end
        end
    catch
        _:_Error ->
            io:format("** ~p\n", [_Error]),
            unknown
    after
        file:close(Fd)
    end.

mk_filter_fun([], [], OutF, OutFInitState) ->
    {OutF, OutFInitState};
mk_filter_fun(SrcIds, PGNs, OutF, OutFInitState) ->
    {fun({_Time, {_Pri, PGN, Src, _}, _} = M, OutState) ->
             case
                 (PGNs == [] orelse lists:member(PGN, PGNs))
                 andalso
                 (SrcIds == [] orelse lists:member(Src, SrcIds))
             of
                 true ->
                     OutF(M, OutState);
                 false ->
                     OutState
             end;
        (M, OutState) ->
             OutF(M, OutState)
     end, OutFInitState}.

mk_expr_filter_fun(Expr, OutF, OutFInitState) ->
    {fun({_Time, {_Pri, _PGN, _Src, _Dst}, _} = M, OutState) ->
             case eval(Expr, M) of
                 true ->
                     OutF(M, OutState);
                 false ->
                     OutState
             end;
        (M, OutState) ->
             OutF(M, OutState)
     end, OutFInitState}.

-define(ISOADDRESSCLAIM_HEADER, " ~-15s ~-40s").
-define(PRODUCTINFORMATION_HEADER, " ~-15s ~-15s ~-8s ~-3s").
-define(CONFIGINFORMATION_HEADER, " ~-15s ~-15s ~-15s").

fmt_devices(WriteF, LA, LB, LC) ->
    WriteF("SRC"),
    WriteF(io_lib:format(?ISOADDRESSCLAIM_HEADER,
                         ["MANUFACTURER", "FUNCTION"])),
    if LB /= [] ->
            WriteF(io_lib:format(
                     ?PRODUCTINFORMATION_HEADER,
                     ["MODEL", "SOFTWARE VSN", "NMEA2000", "LEN"]));
       true ->
            ok
    end,

    if LC /= [] ->
            WriteF(io_lib:format(
                     ?CONFIGINFORMATION_HEADER,
                     ["DESCR1", "DESCR2", "INFO"]));
       true ->
            ok
    end,

    WriteF("\n"),
    WriteF("==="),
    WriteF(io_lib:format(?ISOADDRESSCLAIM_HEADER,
                         ["============", "========"])),
    if LB /= [] ->
            WriteF(io_lib:format(
                     ?PRODUCTINFORMATION_HEADER,
                     ["=====", "============", "========", "==="]));
       true ->
            ok
    end,

    if LC /= [] ->
            WriteF(io_lib:format(
                     ?CONFIGINFORMATION_HEADER,
                     ["======", "======", "===="]));
       true ->
            ok
    end,

    WriteF("\n"),

    fmt_devices0(WriteF, merge(LA, LB, LC)).

merge(LA, LB, LC) ->
    merge0([{Src, {A, undefined, undefined}} || {Src, A} <- LA],
           merge0([{Src, {undefined, B, undefined}} || {Src, B} <- LB],
                  [{Src, {undefined, undefined, C}} || {Src, C} <- LC])).

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
merge_tup({undefined,BX,undefined}, {AY,_BY,CY}) ->
    {AY,BX,CY};
merge_tup({AX,undefined,undefined}, {_AY,BY,CY}) ->
    {AX,BY,CY}.

fmt_devices0(WriteF, [{Src, {A, B, C}} | T]) ->
    WriteF(fmt_src(Src)),
    WriteF(fmt_isoAddressClaim(A)),
    WriteF(fmt_productInformation(B)),
    WriteF(fmt_configInformation(C)),
    WriteF("\n"),
    fmt_devices0(WriteF, T);
fmt_devices0(_, []) ->
    ok.

fmt_src(Src) ->
    io_lib:format("~3w", [Src]).

fmt_isoAddressClaim({_Time, _, {isoAddressClaim, Fields}}) ->
    [_UniqueNumber,
     {manufacturerCode, Code},
     _DeviceInstanceLower,
     _DeviceInstanceUpper,
     {deviceFunction, Function},
     {deviceClass, Class} | _] = Fields,
    io_lib:format(
      ?ISOADDRESSCLAIM_HEADER,
      [get_isoAddressClaim_enum(manufacturerCode, Code),
       get_isoAddressClaim_enum(deviceFunction, {Class, Function})]);
fmt_isoAddressClaim(undefined) ->
    io_lib:format(
      ?ISOADDRESSCLAIM_HEADER,
      ["", ""]).


fmt_productInformation({_Time, _, {productInformation, Fields}}) ->
    [{nmea2000Version, Nmea2000Version},
     {productCode, _ProductCode},
     {modelId, ModelId},
     {softwareVersionCode, SoftwareVersionCode},
     {modelVersion, _ModelVersion},
     {modelSerialCode, _ModelSerialCode},
     {certificationLevel, _CertificationLevel},
     {loadEquivalency, LoadEquivalency} | _] = Fields,
    io_lib:format(?PRODUCTINFORMATION_HEADER,
                  [ModelId,
                   SoftwareVersionCode,
                   io_lib:format("~.3f", [Nmea2000Version*0.001]),
                   io_lib:format("~w", [LoadEquivalency])]);
fmt_productInformation(undefined) ->
    io_lib:format(?PRODUCTINFORMATION_HEADER,
                  ["", "", "", ""]).

fmt_configInformation({_Time, _, {configurationInformation, Fields}}) ->
    [{installationDescription1, InstallationDescription1},
     {installationDescription2, InstallationDescription2},
     {manufacturerInformation, ManufacturerInformation} | _] = Fields,
    io_lib:format(?CONFIGINFORMATION_HEADER,
                  [InstallationDescription1,
                   InstallationDescription2,
                   ManufacturerInformation]);
fmt_configInformation(undefined) ->
    io_lib:format(?CONFIGINFORMATION_HEADER,
                  ["", "", ""]).


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

frame_lost(Src, PGN, Order, ETab, Cnts) ->
    case ets:lookup(ETab, {Src, PGN}) of
        [{_, Order}] ->
            ok;
        _ ->
            counters:add(Cnts, ?CNT_FAST_PACKET_ERRORS, 1),
            ets:insert(ETab, {{Src, PGN}, Order})
    end.

-type expr() :: {'or', expr(), expr()}
              | {'and', expr(), expr()}
              | {'not', expr()}
              | {'pgn' | 'src' | 'dst', integer()}.

%% expr = "(" expr ")" /
%%         expr sep boolean-operator sep expr /
%%         not-keyword sep expr /
%%         test
%% test =  pgn-keyword sep integer* /
%%         src-keyword sep integer* /
%%         dst-keyword sep integer* /
%%
%% Can be rewritten as:
%%   x = y ("and"/"or" y)*
%%   y = "not" x /
%%       "(" x ")"
%%       test
%%
%%   expr    = term "or" expr
%%   term    = factor "and" term
%%   factor  = "not" factor /
%%             "(" expr ")" /
%%             test
%%
%% Recursive descent parser follows.

-spec parse_expr(list()) -> {ok, expr()} | error.
parse_expr(Str0) ->
    try
        {Expr, Str1} = expr(Str0),
        eof = get_tok(Str1),
        {ok, Expr}
    catch
        _X:_Y:_S ->
            io:format("~p:~p\n~p", [_X, _Y, _S]),
            error
    end.

expr(Str0) ->
    {TermL, Str1} = term(Str0),
    case get_tok(Str1) of
        {'or', Str2} ->
            {TermR, Str3} = expr(Str2),
            {{'or', TermL, TermR}, Str3};
        _ ->
            {TermL, Str1}
    end.

term(Str0) ->
    {FactL, Str1} = factor(Str0),
    case get_tok(Str1) of
        {'and', Str2} ->
            {FactR, Str3} = term(Str2),
            {{'and', FactL, FactR}, Str3};
        _ ->
            {FactL, Str1}
    end.

factor(Str0) ->
    case get_tok(Str0) of
        {'not', Str1} when Str1 /= [] ->
            {Fact, Str2} = factor(Str1),
            {{'not', Fact}, Str2};
        {'(', Str1} ->
            {Expr, Str2} = expr(Str1),
            {')', Str3} = get_tok(Str2),
            {Expr, Str3};
        {Test, Str1} ->
            {Test, Str1}
    end.


-define(is_ws(X), (X == $\s orelse X == $\t orelse
                   X == $\n orelse X == $\r)).
-define(is_sep(X), (?is_ws(X) orelse (X) == $( orelse (X) == $))).
-define(is_int(X), ((X >= $0 andalso X =< $9))).

get_tok(S0) ->
    S1 = skip_ws(S0),
    case S1 of
        [$( | S2] ->
            {'(', S2};
        [$) | S2] ->
            {')', S2};
        "or" ++ [H | T] when ?is_sep(H) ->
            {'or', [H | T]};
        "and" ++ [H | T] when ?is_sep(H) ->
            {'and', [H | T]};
        "not" ++ [H | T] when ?is_sep(H) ->
            {'not', [H | T]};
        "pgn" ++ [H | T] when ?is_sep(H) ->
            {Int, S2} = get_integer(skip_ws(T)),
            {{pgn, Int}, S2};
        "src" ++ [H | T] when ?is_sep(H) ->
            {Int, S2} = get_integer(skip_ws(T)),
            {{src, Int}, S2};
        "dst" ++ [H | T] when ?is_sep(H) ->
            {Int, S2} = get_integer(skip_ws(T)),
            {{dst, Int}, S2};
        [] ->
            'eof'
    end.

skip_ws([H | T]) when ?is_ws(H) ->
    skip_ws(T);
skip_ws(S) ->
    S.

get_integer([H | T]) when ?is_int(H) ->
    get_integer(T, [H]).

get_integer([H | T], Acc) when ?is_int(H) ->
    get_integer(T, [H | Acc]);
get_integer(T, Acc) ->
    {list_to_integer(lists:reverse(Acc)), T}.

-spec eval(expr(), n2k:frame()) -> boolean().
eval(Expr, Frame) ->
    case Expr of
        {'or', ExprL, ExprR} ->
            eval(ExprL, Frame) orelse eval(ExprR, Frame);
        {'and', ExprL, ExprR} ->
            eval(ExprL, Frame) andalso eval(ExprR, Frame);
        {'not', ExprR} ->
            not(eval(ExprR, Frame));
        Test ->
            {_Time, {_Pri, PGN, Src, Dst}, _} = Frame,
            case Test of
                {pgn, PGN} -> true;
                {src, Src} -> true;
                {dst, Dst} -> true;
                _ -> false
            end
    end.
