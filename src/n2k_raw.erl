%%% Decoder / encoder for Yacht Device's RAW format.
%%%
%%% Each line represents one NMEA 2000 frame.
%%%
%%% Format:
%%%   hh:mm:ss.ddd D msgid b0 b1 b2 b3 b4 b5 b6 b7<CR><LF>
%%%
%%%     D is direction, 'R' or 'T'
%%%     msgid is 29-bit canid in hex
%%%     b0-b7 is data in hex
-module(n2k_raw).

-export([read_raw_file/1, read_raw_file/3]).
-export([decode_raw/1, encode_raw/1, encode_raw_line/1, encode_raw_frame/2]).

-export_type([line/0]).

-type line() :: string().

-type dir() :: 'rx' | 'tx'.

-spec read_raw_file(FileName :: string()) ->
          [n2k:frame()].
read_raw_file(FName) ->
    lists:reverse(
      read_raw_file(FName, fun(Frame, Acc) -> [Frame | Acc] end, [])).

-spec read_raw_file(FileName :: string(),
                    fun((n2k:frame(), Acc0 :: term()) -> Acc1 :: term()),
                    InitAcc :: term()) ->
          Acc :: term().
read_raw_file(FName, F, InitAcc) ->
    {ok, Fd} = file:open(FName, [read, raw, binary, read_ahead]),
    try
        read_raw_fd(Fd, F, InitAcc)
    after
        file:close(Fd)
    end.

read_raw_fd(Fd, F, Acc) ->
    case file:read_line(Fd) of
        {ok, <<$#, _/binary>>} ->
            read_raw_fd(Fd, F, Acc);
        {ok, Line} ->
            {Frame, _Dir} = decode_raw(Line),
            read_raw_fd(Fd, F, F(Frame, Acc));
        _ ->
            Acc
    end.

-spec decode_raw(Line :: binary()) -> {n2k:frame(), dir()}.
decode_raw(Line0) ->
    %% We handle lines with ending CRLF (proper msg), with just
    %% LF (as returned by file:read_line), and w/o ending (if it
    %% was removed already).
    Line =
        case binary:last(Line0) of
            $\n ->
                Sz = byte_size(Line0),
                Last =
                    case binary:at(Line0, Sz-2) of
                        $\r ->
                            Sz-2;
                        _ ->
                            Sz-1
                    end,
                binary:part(Line0, 0, Last);
            _ ->
                Line0
        end,
    case binary:split(Line, <<" ">>, [global,trim_all]) of
        [TimeB, <<DirCh>>, CanIdB | Ds] ->
            ok;
        [CanIdB | Ds] ->
            TimeB = <<"00:00:00.000">>,
            DirCh = $R
    end,
    <<HrB:2/binary,$:,MinB:2/binary,$:,SecB:2/binary,$.,MsB:3/binary>> = TimeB,
    Hr = binary_to_integer(HrB),
    Min = binary_to_integer(MinB),
    Sec = binary_to_integer(SecB),
    Ms = binary_to_integer(MsB),
    Dir = decode_raw_dir(DirCh),
    CanId = binary_to_integer(CanIdB, 16),
    Data = list_to_binary([binary_to_integer(D, 16) || D <- Ds]),
    Id = n2k:decode_canid(CanId),
    Milliseconds = ((((Hr*60 + Min) * 60) + Sec) * 1000) + Ms,
    {{Milliseconds, Id, Data}, Dir}.

decode_raw_dir($\R) -> rx;
decode_raw_dir($\T) -> tx.

-spec encode_raw({n2k:frame(), dir()}) -> line().
encode_raw({{Time, CanId, Data}, Dir}) ->
    [n2k:fmt_ms_time(Time), $\s, fmt_raw_dir(Dir), $\s,
     fmt_raw_canid(CanId), $\s, fmt_raw_data(Data),
     $\r, $\n].

-spec encode_raw_line({n2k:frame(), dir()}) -> line().
encode_raw_line({{Time, CanId, Data}, Dir}) ->
    [n2k:fmt_ms_time(Time), $\s, fmt_raw_dir(Dir), $\s,
     fmt_raw_canid(CanId), $\s, fmt_raw_data(Data)].

-spec encode_raw_frame(n2k:canid(), binary()) -> line().
%% This line can be sent to a yacht device's gw.  Note that
%% the src in the canid doens't matter; the gw will replace it with
%% its own src.
encode_raw_frame(CanId, Data) ->
    [fmt_raw_canid(CanId), $\s, fmt_raw_data(Data),
     $\r, $\n].

fmt_raw_dir(rx) -> $R;
fmt_raw_dir(tx) -> $T.

fmt_raw_canid(CanId) when is_tuple(CanId) ->
    fmt_raw_canid(n2k:encode_canid(CanId));
fmt_raw_canid(CanId) ->
    n2k:fmt_hex(<<0:3,CanId:29>>, []).

fmt_raw_data(Data) ->
    n2k:fmt_hex(Data, $\s).
