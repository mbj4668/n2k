%%% Decoder / encoder for CANBOAT's Plain Format (CSV)
%%%
%%% Each line represents one NMEA 2000 frame.
%%%
%%% Format:
%%%     timestamp, priority, pgn, src, dst, len, b0, ..., b7
%%%   timestamp is YYYY-MM-DD HH:MM:SS.ddd
%%%   b0-b7 is data in hex
-module(n2k_csv).

-export([read_csv_file/1, read_csv_file/3]).
-export([decode_csv/1, encode_csv/1]).

-type line() :: string().

-spec read_csv_file(FileName :: string()) ->
    [n2k:frame()].
read_csv_file(FName) ->
    lists:reverse(
        read_csv_file(FName, fun(Frame, Acc) -> [Frame | Acc] end, [])
    ).

-spec read_csv_file(
    FileName :: string(),
    fun((n2k:frame(), Acc0 :: term()) -> Acc1 :: term()),
    InitAcc :: term()
) ->
    Acc :: term().
read_csv_file(FName, F, InitAcc) ->
    {ok, Fd} = file:open(FName, [read, raw, binary, read_ahead]),
    try
        read_csv_fd(Fd, F, InitAcc)
    after
        file:close(Fd)
    end.

read_csv_fd(Fd, F, Acc) ->
    case file:read_line(Fd) of
        {ok, <<$#, _/binary>>} ->
            read_csv_fd(Fd, F, Acc);
        {ok, Line0} ->
            Line =
                case binary:last(Line0) of
                    $\n ->
                        binary:part(Line0, 0, byte_size(Line0) - 1);
                    _ ->
                        Line0
                end,
            Frame = decode_csv(Line),
            read_csv_fd(Fd, F, F(Frame, Acc));
        _ ->
            Acc
    end.

-spec decode_csv(Line :: binary()) -> n2k:frame().
decode_csv(Line) ->
    [TimeB, PriB, PGNB, SrcB, DstB, _SzB | Ds] =
        binary:split(Line, <<",">>, [global, trim_all]),
    case TimeB of
        <<HrB:2/binary, $:, MinB:2/binary, $:, SecB:2/binary, $., MsB:3/binary>> ->
            ok;
        <<_YYYY:4/binary, $-, _MM:2/binary, $-, _DD:2/binary, _Sep, HrB:2/binary, $:, MinB:2/binary,
            $:, SecB:2/binary, $., MsB:3/binary, _/binary>> ->
            ok;
        <<_YYYY:4/binary, $-, _MM:2/binary, $-, _DD:2/binary, _Sep, HrB:2/binary, $:, MinB:2/binary,
            $:, SecB:2/binary, _/binary>> ->
            MsB = <<"0">>
    end,
    Hr = binary_to_integer(HrB),
    Min = binary_to_integer(MinB),
    Sec = binary_to_integer(SecB),
    Ms = binary_to_integer(MsB),
    Pri = binary_to_integer(PriB),
    PGN = binary_to_integer(PGNB),
    Src = binary_to_integer(SrcB),
    Dst = binary_to_integer(DstB),
    Data = list_to_binary([binary_to_integer(D, 16) || D <- Ds]),
    Milliseconds = ((((Hr * 60 + Min) * 60) + Sec) * 1000) + Ms,
    {Milliseconds, {Pri, PGN, Src, Dst}, Data}.

-spec encode_csv(n2k:frame()) -> line().
encode_csv({Time, {Pri, PGN, Src, Dst}, Data}) ->
    [
        n2k:fmt_ms_time(Time),
        $,,
        integer_to_list(Pri),
        $,,
        integer_to_list(PGN),
        $,,
        integer_to_list(Src),
        $,,
        integer_to_list(Dst),
        $,,
        integer_to_list(size(Data)),
        $,,
        n2k:fmt_hex(Data, $,),
        $\n
    ].
