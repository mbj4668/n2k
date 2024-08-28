-module(n2k_request).

-export([init_request/3, init_request/4, loop/3]).

-include("n2k_request.hrl").

-define(CONNECT_TIMEOUT, 5000).
%-define(ACTIVE_COUNT, 100).
-define(ACTIVE_COUNT, true).

init_request(Proto, Address, Port) ->
    init_request(Proto, Address, Port, Port).

init_request(Proto, Address, Port, LPort) ->
    Req =
        case Proto of
            udp ->
                ConnectF =
                    fun() ->
                            gen_udp:open(LPort,
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

loop(R, _HandleF, {done, HandleS}) ->
    (R#req.closef)(R#req.sock),
    HandleS;
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
