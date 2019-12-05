%%% Decoder for Yacht Device's DAT format.
%%%
%%% Each line represents one NMEA 2000 packet (assembled frames) or
%%% a DAT service record.
%%%
%%% Format:
%%%     mm PPPP ( ddd | dddddddd | sB d[B] )
%%%   mm ms since boot, resets after 60000
%%%   PPPP CanId or 16#ffffffff for service record
%%%   s sequence number
%%%   B length of byte array
-module(n2k_dat).

-export([read_dat_file/1, read_dat_file/3]).
-export([fmt_service_record/1]).

-type dat_record() :: dat_service_record() | raw_packet().

-type dat_service_record() ::
        {
          Time :: integer() % milliseconds
        , 0
        , -1
        , Data :: binary()
        }.

-type raw_packet() ::
        {
          Time :: integer() % milliseconds
        , Src  :: byte()
        , PGN  :: integer()
        , Data :: binary() % can be decoded w/ n2k_pgn:decode/2
        }.

-spec read_dat_file(FileName :: string()) ->
          [dat_record()].
read_dat_file(FName) ->
    lists:reverse(
      read_dat_file(FName, fun(Frame, Acc) -> [Frame | Acc] end, [])).

-spec read_dat_file(FileName :: string(),
                    fun((dat_record(), Acc0 :: term()) -> Acc1 :: term()),
                    InitAcc :: term()) ->
          Acc :: term().
read_dat_file(FName, F, InitAcc) ->
    {ok, Fd} = file:open(FName, [read, raw, binary, read_ahead]),
    try
        read_dat_fd(Fd, F, InitAcc)
    after
        file:close(Fd)
    end.

read_dat_fd(Fd, F, Acc) ->
    case file:read(Fd, 6) of
        {ok, <<Time:16/little, 16#ffffffff:32>>} ->
            %% service record ->
            {ok, Data} = file:read(Fd, 8),
            read_dat_fd(Fd, F, F({Time, 0, -1, Data}, Acc));
        {ok, <<Time:16/little, CanId:32/little>>} ->
            {_Pri, PGN, Src, _Dst} = n2k:decode_canid(CanId),
            if PGN == 59904 ->
                    {ok, Data} = file:read(Fd, 3);
               true ->
                    case catch n2k_pgn:is_fast(PGN) of
                        true ->
                            {ok, <<_Seq:8, Len:8>>} = file:read(Fd, 2),
                            {ok, Data} = file:read(Fd, Len);
                        _ ->
                            {ok, Data} = file:read(Fd, 8)
                    end
            end,
            Packet = {Time, Src, PGN, Data},
            read_dat_fd(Fd, F, F(Packet, Acc));
        _ ->
            Acc
    end.

-spec fmt_service_record(dat_service_record()) -> string().
fmt_service_record({Time, 0, -1, Data}) ->
    Str =
        case Data of
            <<$Y,$D,$V,$R,_,_,_,_>> ->
                binary_to_list(Data);
            <<$E,_/binary>> ->
                "last record";
            <<$T,_/binary>> ->
                "1 minute silence";
            _ ->
                "unknown"
        end,
    [n2k:fmt_ms_time(Time), $\s, Str].
