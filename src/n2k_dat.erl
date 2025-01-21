%%% Decoder for Yacht Device's DAT format.
%%%
%%% Each line represents one NMEA 2000 message (assembled frames) or
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

-type dat_record() :: dat_service_record() | raw_message().

-type dat_service_record() ::
    {
        % milliseconds
        Time :: integer(),
        'service',
        Data :: binary()
    }.

-type raw_message() ::
    {
        % milliseconds
        Time :: integer(),
        Id :: n2k:canid(),
        % can be decoded w/ n2k_pgn:decode/2
        Data :: binary()
    }.

-spec read_dat_file(FileName :: string()) ->
    [dat_record()].
read_dat_file(FName) ->
    lists:reverse(
        read_dat_file(FName, fun(Record, Acc) -> [Record | Acc] end, [])
    ).

-spec read_dat_file(
    FileName :: string(),
    fun((dat_record(), Acc0 :: term()) -> Acc1 :: term()),
    InitAcc :: term()
) ->
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
            read_dat_fd(Fd, F, F({Time, 'service', Data}, Acc));
        {ok, <<Time:16/little, CanId:32/little>>} ->
            Id = n2k:decode_canid(CanId),
            {_Pri, PGN, _Src, _Dst} = Id,
            if
                PGN == 59904 ->
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
            read_dat_fd(Fd, F, F({Time, Id, Data}, Acc));
        _ ->
            Acc
    end.

-spec fmt_service_record(dat_service_record()) -> string().
fmt_service_record({Time, 'service', Data}) ->
    Str =
        case Data of
            <<$Y, $D, $V, $R, $\s, $v, $0, $4>> ->
                binary_to_list(Data);
            <<$E, _/binary>> ->
                "last record";
            <<$T, _/binary>> ->
                "1 minute silence";
            _ ->
                "unknown"
        end,
    [n2k:fmt_ms_time(Time), $\s, Str].
