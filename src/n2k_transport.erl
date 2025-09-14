%%% Transport and encoding utility functions.
-module(n2k_transport).

-export([open_raw_ip/3, open_raw_ip/4]).
-export([send/2, send_fast/2, recv/4, close/1]).

-export_type([transport/0]).

-record(n2k_transport, {
    buf = undefined :: 'undefined' | binary(),
    sendf,
    closef
}).

-opaque transport() :: #n2k_transport{}.

-define(CONNECT_TIMEOUT, 5000).
%-define(ACTIVE_COUNT, 100).
-define(ACTIVE_COUNT, true).

-spec open_raw_ip(
    udp | tcp,
    inet:ip_address(),
    inet:port_number()
) ->
    {ok, transport()} | {error, term()}.
%% Opens a IP (udp or tcp) based connection to a device using the RAW protocol.
open_raw_ip(Proto, Address, Port) ->
    open_raw_ip(Proto, Address, Port, Port).

open_raw_ip(udp, Address, Port, LPort) ->
    case gen_udp:open(LPort, [binary, {active, ?ACTIVE_COUNT}]) of
        {ok, Sock} ->
            SendF =
                fun(Frame) ->
                    Packet = n2k_raw:encode_raw_frame(Frame),
                    gen_udp:send(Sock, Address, Port, Packet)
                end,
            CloseF = fun() -> gen_udp:close(Sock) end,
            {ok, #n2k_transport{sendf = SendF, closef = CloseF}};
        {error, Error} ->
            {error, Error}
    end;
open_raw_ip(tcp, Address, Port, _) ->
    TcpOpts = [
        binary,
        {active, ?ACTIVE_COUNT},
        {packet, line}
    ],
    case gen_tcp:connect(Address, Port, TcpOpts, ?CONNECT_TIMEOUT) of
        {ok, Sock} ->
            SendF =
                fun(Frame) ->
                    Packet = n2k_raw:encode_raw_frame(Frame),
                    gen_tcp:send(Sock, Packet)
                end,
            CloseF = fun() -> gen_tcp:close(Sock) end,
            {ok, #n2k_transport{sendf = SendF, closef = CloseF}};
        {error, Error} ->
            {error, Error}
    end.

send(#n2k_transport{sendf = SendF}, Frame) ->
    SendF(Frame).

send_fast(#n2k_transport{sendf = SendF}, {CanIdInt, FramesData}) ->
    lists:foreach(
        fun(FrameData) ->
            ok = SendF({-1, CanIdInt, FrameData}),
            timer:sleep(1)
        end,
        FramesData
    ).

close(#n2k_transport{closef = CloseF}) ->
    CloseF().

-spec recv(
    transport(),
    binary | frame | {message, PGNs :: [integer()] | all, Other :: frame | ignore},
    HandleF :: fun(
        (
            {binary, binary()} | {frame, n2k:frame()} | {message, n2k:message()} | term(),
            State0 :: term()
        ) -> {done, Result :: term()} | State1 :: term()
    ),
    HandleInitState :: term()
) ->
    Result :: term().
%% Receives data from `Transport`.  When data is received, the `HandleF` is invoked.  The first
%% argument depends on the given `Format`.  If the process receives any other message, it is
%% passed as-is to `HandleF`.  This can be used to handle timers etc.
recv(Transport, Format, HandleF, HandleInitS) ->
    {F, S} = init_recv(Format, HandleF, HandleInitS),
    loop(Transport, F, S).

init_recv(Format, HandleF, HandleInitS) ->
    case Format of
        binary ->
            {
                fun
                    (Line, HandleS) when is_binary(Line) ->
                        HandleF({binary, Line}, HandleS);
                    (Else, HandleS) ->
                        HandleF(Else, HandleS)
                end,
                HandleInitS
            };
        frame ->
            {
                fun
                    (Line, HandleS) when is_binary(Line) ->
                        {Frame, _Dir} = n2k_raw:decode_raw(Line),
                        HandleF({frame, Frame}, HandleS);
                    (Else, HandleS) ->
                        HandleF(Else, HandleS)
                end,
                HandleInitS
            };
        {message, PGNs, Other} ->
            {
                fun
                    (_, {done, _} = Done) ->
                        Done;
                    (Line, {N2kS0, HandleS0}) when is_binary(Line) ->
                        {Frame, _Dir} = n2k_raw:decode_raw(Line),
                        {_Time, {_Prio, PGN, _Src, _Dst}, _Data} = Frame,
                        case PGNs == all orelse lists:member(PGN, PGNs) of
                            true ->
                                case n2k:decode_nmea(Frame, N2kS0) of
                                    {false, N2kS1} ->
                                        {N2kS1, HandleS0};
                                    {true, Message, N2kS1} ->
                                        case HandleF({message, Message}, HandleS0) of
                                            {done, _} = Done ->
                                                Done;
                                            HandleS1 ->
                                                {N2kS1, HandleS1}
                                        end;
                                    {error, _, N2kS1} ->
                                        {N2kS1, HandleS0}
                                end;
                            false when Other == frame ->
                                case HandleF({frame, Frame}, HandleS0) of
                                    {done, _} = Done ->
                                        Done;
                                    HandleS1 ->
                                        {N2kS0, HandleS1}
                                end;
                            false ->
                                {N2kS0, HandleS0}
                        end;
                    (Else, {N2kS0, HandleS0}) ->
                        case HandleF(Else, HandleS0) of
                            {done, _} = Done ->
                                Done;
                            HandleS1 ->
                                {N2kS0, HandleS1}
                        end
                end,
                {n2k:decode_nmea_init(), HandleInitS}
            }
    end.

loop(_Tr, _F, {done, Res}) ->
    Res;
loop(Tr, F, S0) ->
    receive
        {udp, _, _, _, Data} ->
            {Tr1, S1} = handle_data(Data, Tr, F, S0),
            loop(Tr1, F, S1);
        {tcp, _, Data} ->
            {Tr1, S1} = handle_data(Data, Tr, F, S0),
            loop(Tr1, F, S1);
        {udp_passive, Sock} ->
            inet:setopts(Sock, [{active, ?ACTIVE_COUNT}]),
            loop(Tr, F, S0);
        {tcp_passive, Sock} ->
            inet:setopts(Sock, [{active, ?ACTIVE_COUNT}]),
            loop(Tr, F, S0);
        Else ->
            S1 = F(Else, S0),
            loop(Tr, F, S1)
    end.

handle_data(<<>>, Tr, _, S) ->
    {Tr, S};
handle_data(Data, #n2k_transport{buf = Buf} = Tr, F, S0) ->
    {Buf1, Lines} = lines(Buf, Data),
    S1 = lists:foldl(F, S0, Lines),
    {Tr#n2k_transport{buf = Buf1}, S1}.

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
