%%% Decoder for Yacht Device's CAN format.
%%%
%%% Each record represents one NMEA 2000 frame or a CAN service
%%% record.
%%%
%%% Format:
%%%   Each record is 16 bytes long.
%%%   0                   1                   2                   3
%%%   0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
%%%   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%%   |   Time (minutes)  |N| Len |D|T|     Time (milliseconds)       |
%%%   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%%   |                       CAN Id                                  |
%%%   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%%   |                       Data                                    |
%%%   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%%   |                       Data                                    |
%%%   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%%%
%%%   N - 0 means first CAN interface, 1 means second CAN interface
%%%   D - 0 means 'rx', 1 means 'tx'
%%%   T - 0 means CAN frame, 1 means service record
-module(n2k_can).

-export([read_can_file/1, read_can_file/3]).
-export([decode_can/1]).
-export([fmt_service_record/1]).

-type can_frame() :: can_service_record() | n2k:frame().

-type can_service_record() ::
    {
        % milliseconds
        Time :: integer(),
        'service',
        Data :: binary()
    }.

-type dir() :: 'rx' | 'tx'.

-spec read_can_file(FileName :: string()) ->
    [can_frame()].
read_can_file(FName) ->
    lists:reverse(
        read_can_file(FName, fun(Frame, Acc) -> [Frame | Acc] end, [])
    ).

-spec read_can_file(
    FileName :: string(),
    fun((can_frame(), Acc0 :: term()) -> Acc1 :: term()),
    InitAcc :: term()
) ->
    Acc :: term().
read_can_file(FName, F, InitAcc) ->
    {ok, Fd} = file:open(FName, [read, raw, binary, read_ahead]),
    try
        read_can_fd(Fd, F, InitAcc)
    after
        file:close(Fd)
    end.

read_can_fd(Fd, F, Acc) ->
    case file:read(Fd, 16) of
        {ok, Record} ->
            {Frame, _Dir} = decode_can(Record),
            read_can_fd(Fd, F, F(Frame, Acc));
        _ ->
            lists:reverse(Acc)
    end.

-spec decode_can(Record :: binary()) -> {can_frame(), dir()}.
decode_can(Record) ->
    <<HdrB:16/little, Ms:16/little, MsgId:32/little, DataWPad/binary>> =
        Record,
    <<Type:1, DirI:1, Len0:3, _Interface:1, Minutes:10>> = <<HdrB:16>>,
    <<MsgIdB:4/binary>> = <<MsgId:32>>,
    Dir = decode_can_dir(DirI),
    Len = Len0 + 1,
    <<Data:Len/binary, _/binary>> = DataWPad,
    Id =
        case MsgIdB of
            <<16#ffffffff:32>> when Type == 0 ->
                service;
            <<_:3, CanId:29>> when Type == 0 ->
                n2k:decode_canid(CanId);
            <<_:21, SmallId:11>> ->
                SmallId
        end,
    Milliseconds = Minutes * 60000 + Ms,
    {{Milliseconds, Id, Data}, Dir}.

decode_can_dir(0) -> rx;
decode_can_dir(1) -> tx.

-spec fmt_service_record(can_service_record()) -> string().
fmt_service_record({Time, 'service', Data}) ->
    Str =
        case Data of
            <<$Y, $D, $V, $R, $\s, $v, $0, $5>> ->
                binary_to_list(Data);
            <<$Y, $I, C0Speed:4, C1Speed:4, _/binary>> ->
                "speed CAN#0: " ++ fmt_speed(C0Speed) ++
                    " CAN#1: " ++ fmt_speed(C1Speed);
            _ ->
                "unknown"
        end,
    [n2k:fmt_ms_time(Time), $\s, Str].

fmt_speed(Speed) ->
    case Speed of
        1 -> "50 kbps";
        2 -> "125 kbps";
        3 -> "250 kbps";
        4 -> "500 kbps";
        5 -> "1000 kbps";
        15 -> "unavailable";
        _ -> "reserved"
    end.
