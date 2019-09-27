%%% Decoder / encoder for Yacht Device's DAT format.
%%%
%%% Format:
%%%     mm PPPP ( ddd | dddddddd | sB d[B] )
%%%   mm ms since boot, resets after 60000
%%%   PPPP CanId or 16#ffffffff for service record
%%%   s sequence number
%%%   B length of byte array
-module(n2k_dat).

-compile(export_all).

decode_dat_file(FName) ->
    {ok, Fd} = file:open(FName, [read, raw, binary, read_ahead]),
    try
        read_dat_file(Fd, [])
    after
        file:close(Fd)
    end.

read_dat_file(Fd, Acc) ->
    case file:read(Fd, 6) of
        {ok, <<Time:16/little, 16#ffffffff:32>>} ->
            %% service record ->
            {ok, Data} = file:read(Fd, 8),
            read_dat_file(Fd, [{Time, -1, Data} | Acc]);
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
            Packet = {Time, PGN, Src, n2k_pgn:decode(PGN, Data)},
            read_dat_file(Fd, [Packet | Acc]);
        _ ->
            Acc
    end.
