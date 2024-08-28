%%% Implementation of the `n2k` command line tool.
%%%
%%% Reads 'raw', 'csv', 'dat' and 'can' files, and converts
%%% to 'csv' or pretty text.
-module(n2k_script).
-include("n2k_request.hrl").

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
                    " of tests, where each test is 'pgn INT', 'src INT', "
                    " 'dst INT, or 'dev INT'.  For example"},
                {pre, "  pgn 59904 and (src 81 or src 11)"}
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
                             Merged =
                                 n2k_devices:merge_device_information(X, Y, Z),
                             n2k_devices:print_devices(WriteF, Merged);
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
                 help => "IP address or hostname of the NMEA 2000 gateway",
                 cb => fun opt_address/3},
               #{long => "port",
                 type => int, default => 1457,
                 help => "TCP port to connect to, or UDP port to listen to"}],
      required_cmd => true,
      cmds =>
          [cmd_dump(),
           cmd_get_devices(),
           cmd_maretron_get_depth()]}.

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

opt_address(_, #{address := Address0} = Opts, _) ->
    case inet:parse_address(Address0) of
        {ok, Address} ->
            Opts#{address => Address};
        _ ->
            Opts
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
    {_Cmd, Opts} = ReqCmd,
    #{protocol := Proto, address := Address, port := Port} = Opts,
    io:format("Connecting to ~p\n", [Address]),
    {ok, R} = n2k_request:init_request(Proto, Address, Port),
    S = #dump{outfmt = OutFmt, expr = Expr},
    n2k_request:loop(R, fun dump_raw_line/2, S).

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

do_get_devices(_Env, CmdStack, Timeout) ->
    [ReqCmd | _] = CmdStack,
    {_Cmd, Opts} = ReqCmd,
    #{protocol := Proto, address := Address, port := Port} = Opts,
    case n2k_devices:get_devices(Proto, Address, Port, Timeout) of
        {ok, Res} ->
            n2k_devices:print_devices(fun io:put_chars/1, Res),
            halt(0)
    end.

cmd_maretron_get_depth() ->
    #{cmd => "maretron-get-depth",
      opts => [#{short => $d, long => "device",
                 type => int}],
      cb => fun do_maretron_get_depth/3}.

do_maretron_get_depth(_Env, CmdStack, Device) ->
    [ReqCmd | _] = CmdStack,
    {_Cmd, Opts} = ReqCmd,
    #{protocol := Proto, address := Address, port := Port} = Opts,
    case n2k_maretron:get_depth(Proto, Address, Port, Device) of
        {ok, Msg} ->
            io:format("~s\n", [n2k:fmt_nmea_message(Msg, true)])
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
%%         dev-keyword sep integer* /
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
            %io:format("~p:~p\n~p", [_X, _Y, _S]),
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
        "dev" ++ [H | T] when ?is_sep(H) ->
            {Int, S2} = get_integer(skip_ws(T)),
            {{dev, Int}, S2};
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
                {dev, Dev} -> Dev == Src orelse Dev == Dst;
                _ -> false
            end
    end.
