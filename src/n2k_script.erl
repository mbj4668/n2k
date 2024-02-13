%%% Implementation of the `n2k` command line tool.
%%%
%%% Reads 'raw', 'csv', 'dat' and 'can' files, and converts
%%% to 'csv' or pretty text.
-module(n2k_script).
-export([main/1]).

-define(CNT_MESSAGES, 1).
-define(CNT_FAST_PACKET_ERRORS, 2).
-define(CNT_SIZE, 2).

main(Args) ->
    eclip:parse(Args, spec(), #{}).

spec() ->
    #{help => {doc,
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
                  , {"errors", "Print errors"}]}
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
               #{long => "src", metavar => "SrcId", multiple => true,
                 help => "Only include messages from the given devices"},
               #{long => "pgn", multiple => true, type => int,
                 help => "Only include messages with the given pgns"},
               #{short => $o, name => outfile}],
      args => [#{name => infname, metavar => "INFILE"}],
      cb => fun do_convert/10}.

do_convert(Env, _CmdStack, Quiet, InFmt0, OutFmt, PStr,
           SrcIds, PGNs, OutFName, InFName) ->
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
                    {fun({_, {_, PGN, Src, _}, _} = Frame, {State0, X, Y})
                           when PGN == 60928 orelse PGN == 126996 ->
                             case n2k:decode_nmea(Frame, State0) of
                                 {true, Msg, State1} when PGN == 60928 ->
                                     case lists:keymember(Src, 1, X) of
                                         false ->
                                             {State1, [{Src, Msg} | X], Y};
                                         true ->
                                             {State1, X, Y}
                                     end;
                                 {true, Msg, State1} when PGN == 126996 ->
                                     case lists:keymember(Src, 1, Y) of
                                         false ->
                                             {State1, X, [{Src, Msg} | Y]};
                                         true ->
                                             {State1, X, Y}
                                     end;
                                 {false, State1} ->
                                     {State1, X, Y};
                                 {error, _, State1} ->
                                     {State1, X, Y}
                             end;
                        (eof, {_, X0, Y0}) ->
                             X = lists:keysort(1, X0),
                             Y = lists:keysort(1, Y0),
                             fmt_devices(WriteF, X, Y);
                        (_, S) ->
                             S
                     end,
                     {n2k:decode_nmea_init(), [], []}};
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
        {F, FInitState} = mk_filter_fun(SrcIds, PGNs, OutF, OutFInitState),
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
            io:format("** Error: ~s\n\n", [Reason]),
            eclip:print_help(standard_io, Env),
            halt(1);
        _:terminated ->
            halt(1);
        _:_Error:_StackTrace ->
            io:format("** ~p\n  ~p\n", [_Error, _StackTrace]),
            halt(1)
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

-define(ISOADDRESSCLAIM_HEADER, " ~-15s ~-40s").
-define(PRODUCTINFORMATION_HEADER, " ~-15s ~-15s ~-8s ~-3s").

fmt_devices(WriteF, LA, LB) ->
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
    WriteF("\n"),
    fmt_devices0(WriteF, LA, LB).

fmt_devices0(WriteF, [{Src, A} | TA], [{Src, B} | TB]) ->
    WriteF(fmt_src(Src)),
    WriteF(fmt_isoAddressClaim(A)),
    WriteF(fmt_productInformation(B)),
    WriteF("\n"),
    fmt_devices0(WriteF, TA, TB);
fmt_devices0(WriteF, [{SrcA, A} | TA], [{SrcB, _} | _] = LB)
  when SrcA < SrcB ->
    WriteF(fmt_src(SrcA)),
    WriteF(fmt_isoAddressClaim(A)),
    WriteF("\n"),
    fmt_devices0(WriteF, TA, LB);
fmt_devices0(WriteF, LA, [{SrcB, B} | TB]) ->
    WriteF(fmt_src(SrcB)),
    WriteF(fmt_productInformation(B)),
    WriteF("\n"),
    fmt_devices0(WriteF, LA, TB);
fmt_devices0(WriteF, [{SrcA, A} | TA], []) ->
    WriteF(fmt_src(SrcA)),
    WriteF(fmt_isoAddressClaim(A)),
    WriteF("\n"),
    fmt_devices0(WriteF, TA, []);
fmt_devices0(_, [], []) ->
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

frame_lost(Src, PGN, Order, ETab, Cnts) ->
    case ets:lookup(ETab, {Src, PGN}) of
        [{_, Order}] ->
            ok;
        _ ->
            counters:add(Cnts, ?CNT_FAST_PACKET_ERRORS, 1),
            ets:insert(ETab, {{Src, PGN}, Order})
    end.
