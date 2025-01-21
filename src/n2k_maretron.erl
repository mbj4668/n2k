-module(n2k_maretron).
-export([get_depth/4]).

-include("n2k_request.hrl").

-record(get_depth, {
    n2k_state = n2k:decode_nmea_init(),
    dev
}).

%% Work in progress.

get_depth(Proto, Address, Port, Device) ->
    {ok, R} = n2k_request:init_request(Proto, Address, Port),
    {CanIdInt, Frames} = nmeaCommandGroupFunction_Request(Device),
    lists:foreach(
        fun(Frame) ->
            RawFrame = n2k_raw:encode_raw_frame(CanIdInt, Frame),
            ok = (R#req.sendf)(R#req.sock, RawFrame),
            timer:sleep(10)
        end,
        Frames
    ),
    Msg = n2k_request:loop(
        R,
        fun get_depth_raw_line/2,
        #get_depth{dev = Device}
    ),
    {ok, Msg}.

%% FIXME: generalize this Request-Response pattern

%% FIXME: on timeout, re-send, abort after N attempts.
get_depth_raw_line(Line, S) when is_binary(Line) ->
    {Frame, _Dir} = n2k_raw:decode_raw(Line),
    {_Time, {_Pri, PGN, Src, _Dst}, _Data} = Frame,
    if
        PGN == 126720 andalso Src == S#get_depth.dev ->
            case n2k:decode_nmea(Frame, S#get_depth.n2k_state) of
                {true, Msg, _N2kState1} ->
                    {done, Msg};
                {false, N2kState1} ->
                    S#get_depth{n2k_state = N2kState1};
                {error, _, N2kState1} ->
                    S#get_depth{n2k_state = N2kState1}
            end;
        true ->
            S
    end.

nmeaCommandGroupFunction_Request(Dst) ->
    CanId = {_Pri = 4, 126208, _Src = 95, Dst},
    Data = <<0, 0, 239, 1, 255, 255, 255, 255, 255, 255, 1, 55, 0>>,
    n2k:encode_nmea_fast_message(CanId, Data, 1).
