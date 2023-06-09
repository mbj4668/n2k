-module(n2k_devices).
-export([scan/0, scan/2]).

-include_lib("kernel/include/logger.hrl").

-define(ACTIVE_COUNT, 10).

-record(state, {
          sock,
          addr,
          buf,
          n2k_state
       }).

-record(rstate, {
          sock,
          buf,
          n2k_state
       }).

scan() ->
    scan({192,168,0,99}, 1457).

scan(IpAddress, UdpPort) ->
    put(order, 0),
    {ok, Sock} = gen_udp:open(0, []),
    S = #state{sock = Sock,
               addr = {IpAddress, UdpPort}},

    RS0 = init_rstate(S),
    %% send isoRequest for 60928
    send_nmea_message(S, 255, 59904, <<60928:24/little-unsigned>>),
    %% collect all results, wait 1 second
    IsoAddressClaimL = collect_replies(RS0, 60928, 1000),
    close_rstate(RS0),
    N2kDeviceAddrL = lists:usort([Src || {Src, _} <- IsoAddressClaimL]),

    %% for each device, send isoRequest for 126996
    ProductInformationL =
        lists:foldl(
          fun(N2kDeviceAddr, Acc) ->
                  Acc ++ n2k_rpc_isoRequest(S, N2kDeviceAddr, 126996)
          end, [], N2kDeviceAddrL),
    WriteF = fun(Bin) -> io:put_chars(Bin) end,
    fmt_devices(WriteF, verbose, IsoAddressClaimL, ProductInformationL).

n2k_rpc_isoRequest(S, N2kDeviceAddr, PGN) ->
    n2k_rpc_isoRequest(5, S, N2kDeviceAddr, PGN).

n2k_rpc_isoRequest(0, _S, _N2kDeviceAddr, _PGN) ->
    [];
n2k_rpc_isoRequest(N, S, N2kDeviceAddr, PGN) ->
    RS1 = init_rstate(S),
    send_nmea_message(S, N2kDeviceAddr, 59904, <<PGN:24/little-unsigned>>),
    case collect_reply(RS1, N2kDeviceAddr, PGN, 1000) of
        [] ->
            close_rstate(RS1),
            n2k_rpc_isoRequest(N-1, S, N2kDeviceAddr, PGN);
        Reply ->
            close_rstate(RS1),
            Reply
    end.


send_nmea_message(S, Dst, PGN, Payload) ->
    CanId = {_Prio = 2, PGN, _Src = 255, Dst},
    case n2k_pgn:is_fast(PGN) of
        false ->
            {CanIdInt, Frame} = n2k:encode_nmea_message(CanId, Payload),
            RawFrame = n2k_raw:encode_raw_frame(CanIdInt, Frame),
            gen_udp_send(S, RawFrame);
        true ->
            Order = get(order),
            {CanIdInt, Frames} =
                n2k:encode_nmea_fast_message(CanId, Payload, Order),
            lists:foreach(
              fun(Frame) ->
                      RawFrame = n2k_raw:encode_raw_frame(CanIdInt, Frame),
                      ok = gen_udp_send(S, RawFrame),
                      timer:sleep(10)
              end, Frames),
            NewOrder = (Order + 1) rem 8,
            put(order, NewOrder)
    end.

gen_udp_send(#state{sock = Sock, addr = Addr}, Data) ->
    gen_udp:send(Sock, Addr, iolist_to_binary(Data)).

init_rstate(S) ->
    {_, UdpPort} = S#state.addr,
    {ok, Sock} = gen_udp:open(UdpPort, [binary, {active, ?ACTIVE_COUNT}]),
    #rstate{sock = Sock, buf = undefined, n2k_state = n2k:decode_nmea_init()}.

close_rstate(#rstate{sock = Sock}) ->
    gen_udp:close(Sock),
    flush_udp(Sock),
    ok.

flush_udp(Sock) ->
    receive
        {udp, Sock, _, _, _} ->
            flush_udp(Sock);
        {udp_passive, Sock} ->
            flush_udp(Sock)
    after
        0 ->
           ok
    end.

collect_reply(RS, Src, PGN, Timeout) ->
    Ref = make_ref(),
    erlang:send_after(Timeout, self(), {timeout, Ref}),
    collect_replies_loop(RS, Src, PGN, Ref, one, []).

collect_replies(RS, PGN, Timeout) ->
    Ref = make_ref(),
    erlang:send_after(Timeout, self(), {timeout, Ref}),
    collect_replies_loop(RS, any, PGN, Ref, all, []).

collect_replies_loop(RS, Src, PGN, Ref, How, Acc) ->
    receive
        {timeout, Ref} ->
            Acc;
        {udp, _, _, _, Data} ->
            {RS1, Acc1} = handle_data(Data, RS, PGN, Acc),
            case Acc1 of
                [{Src, _}] when How == one ->
                    Acc1;
                _ when How == one ->
                    collect_replies_loop(RS1, Src, PGN, Ref, How, Acc);
                _ ->
                    collect_replies_loop(RS1, Src, PGN, Ref, How, Acc1)
            end;
        {udp_passive, Sock} ->
            inet:setopts(Sock, [{active, ?ACTIVE_COUNT}]),
            collect_replies_loop(RS, Src, PGN, Ref, How, Acc)
    end.

handle_data(<<>>, RS, _PGN, Acc) ->
    {RS, Acc};
handle_data(Data, #rstate{buf = Buf} = RS, PGN, Acc) ->
    {Buf1, Lines} = lines(Buf, Data),
    lists:foldl(
      fun(Line, {RS0, Acc0}) ->
              handle_raw_line(Line, RS0, PGN, Acc0)
      end,
      {RS#rstate{buf = Buf1}, Acc},
      Lines).

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

%% Line is unparsed bytes; one line of RAW format.
handle_raw_line(Line, #rstate{n2k_state = N2kState0} = RS, PGN, Acc0) ->
    {Frame, _Dir} = n2k_raw:decode_raw(Line),
    case Frame of
        {_Time, {_Pri, PGN, Src, _Dst}, _Data} ->
            {N2kState2, Acc1} =
                case n2k:decode_nmea(Frame, N2kState0) of
                    {true, Message, N2kState1} ->
                        {N2kState1, [{Src, Message} | Acc0]};
                    {false, N2kState1} ->
                        {N2kState1, Acc0};
                    {error, Error, N2kState1} ->
                        ?LOG_DEBUG(fun n2k:fmt_error/1, Error),
                        {N2kState1, Acc0}
                end,
            {RS#rstate{n2k_state = N2kState2}, Acc1};
        _ ->
            {RS, Acc0}
    end.


-define(ISOADDRESSCLAIM_HEADER, " ~-15s ~-40s").
-define(PRODUCTINFORMATION_HEADER, " ~-15s ~-15s ~-8s ~-3s").
-define(VERBOSE_PRODUCTINFORMATION_HEADER,
        " ~-9s ~-15s ~-25s ~-20s ~-15s ~-8s ~-4s ~-3s").

fmt_devices(WriteF, How, LA0, LB0) ->
    LA = lists:ukeysort(1, LA0),
    LB = lists:ukeysort(1, LB0),
    WriteF("SRC"),
    WriteF(io_lib:format(?ISOADDRESSCLAIM_HEADER,
                         ["MANUFACTURER", "FUNCTION"])),
    if LB /= [], How == verbose ->
            WriteF(io_lib:format(
                     ?VERBOSE_PRODUCTINFORMATION_HEADER,
                     ["PROD CODE",
                      "MODEL", "MODEL VSN", "MODEL SERIAL",
                      "SOFTWARE VSN",
                      "NMEA2000", "CERT",
                      "LEN"]));
       LB /= [] ->
            WriteF(io_lib:format(
                     ?PRODUCTINFORMATION_HEADER,
                     ["MODEL", "SOFTWARE VSN", "NMEA2000", "LEN"]));
       true ->
            ok
    end,
    WriteF("\n"),
    WriteF("==="),
    WriteF(io_lib:format(?ISOADDRESSCLAIM_HEADER,
                         ["============", "========"])),
    if LB /= [], How == verbose ->
            WriteF(io_lib:format(
                     ?VERBOSE_PRODUCTINFORMATION_HEADER,
                     ["=========",
                      "=====", "=========", "============",
                      "============",
                      "========", "====",
                      "==="]));
       LB /= [] ->
            WriteF(io_lib:format(
                     ?PRODUCTINFORMATION_HEADER,
                     ["=====", "============", "========", "==="]));
       true ->
            ok
    end,
    WriteF("\n"),
    fmt_devices0(WriteF, How, LA, LB).

fmt_devices0(WriteF, How, [{Src, A} | TA], [{Src, B} | TB]) ->
    WriteF(fmt_src(Src)),
    WriteF(fmt_isoAddressClaim(A)),
    WriteF(fmt_productInformation(How, B)),
    WriteF("\n"),
    fmt_devices0(WriteF, How, TA, TB);
fmt_devices0(WriteF, How, [{SrcA, A} | TA], [{SrcB, _} | _] = LB)
  when SrcA < SrcB ->
    WriteF(fmt_src(SrcA)),
    WriteF(fmt_isoAddressClaim(A)),
    WriteF("\n"),
    fmt_devices0(WriteF, How, TA, LB);
fmt_devices0(WriteF, How, LA, [{SrcB, B} | TB]) ->
    WriteF(fmt_src(SrcB)),
    WriteF(fmt_productInformation(How, B)),
    WriteF("\n"),
    fmt_devices0(WriteF, How, LA, TB);
fmt_devices0(WriteF, How, [{SrcA, A} | TA], []) ->
    WriteF(fmt_src(SrcA)),
    WriteF(fmt_isoAddressClaim(A)),
    WriteF("\n"),
    fmt_devices0(WriteF, How, TA, []);
fmt_devices0(_, _, [], []) ->
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
       get_isoAddressClaim_enum(deviceFunction, {Class, Function})]).

fmt_productInformation(normal, {_Time, _, {productInformation, Fields}}) ->
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

fmt_productInformation(verbose, {_Time, _, {productInformation, Fields}}) ->
    [{nmea2000Version, Nmea2000Version},
     {productCode, ProductCode},
     {modelId, ModelId},
     {softwareVersionCode, SoftwareVersionCode},
     {modelVersion, ModelVersion},
     {modelSerialCode, ModelSerialCode},
     {certificationLevel, CertificationLevel},
     {loadEquivalency, LoadEquivalency} | _] = Fields,
    io_lib:format(?VERBOSE_PRODUCTINFORMATION_HEADER,
                  [io_lib:format("~w", [ProductCode]),
                   ModelId,
                   ModelVersion,
                   ModelSerialCode,
                   SoftwareVersionCode,
                   io_lib:format("~.3f", [Nmea2000Version*0.001]),
                   if is_integer(CertificationLevel) ->
                           io_lib:format("~w", [CertificationLevel]);
                      true ->
                           "-"
                   end,
                   io_lib:format("~w", [LoadEquivalency])]).


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
