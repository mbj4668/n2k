-module(n2k_can).

%% FIXME: cleaup

-compile(export_all).

can2raw(InFName, OutFName) ->
    {ok, InFd} = file:open(InFName, [read, raw, binary, read_ahead]),
    {ok, OutFd} = file:open(OutFName, [write, raw, binary, delayed_write]),
    try
        F = fun(CanRecord) ->
                    ok = file:write(OutFd, n2k_raw:encode_raw(CanRecord))
            end,
        can_foreach(InFd, F, false)
    after
        file:close(InFd),
        file:close(OutFd)
    end.

can_foreach(InFd, F, DecodeCanId) ->
    case file:read(InFd, 16) of
        {ok, Record} ->
            case decode_can(Record, DecodeCanId) of
                {_Time, _Dir, CanId, _Data} = CanRecord when CanId /= service ->
                    F(CanRecord);
                _ ->
                    ok
            end,
            can_foreach(InFd, F, DecodeCanId);
        _ ->
            ok
    end.

read_can_file(FName) ->
    {ok, Fd} = file:open(FName, [read, raw, binary, read_ahead]),
    try
        read_can_file(Fd, [])
    after
        file:close(Fd)
    end.

read_can_file(Fd, Acc) ->
    case file:read(Fd, 16) of
        {ok, Record} ->
            read_can_file(Fd, [decode_can(Record, true) | Acc]);
        _ ->
            lists:reverse(Acc)
    end.

decode_can(Record, DecodeCanId) ->
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
                if DecodeCanId ->
                        n2k:decode_canid(CanId);
                   true ->
                        CanId
                end;
            <<_:21, SmallId:11>> ->
                SmallId
        end,
    Milliseconds = Minutes*60000 + Ms,
    {Milliseconds, Dir, Id, Data}.

decode_can_dir(0) -> rx;
decode_can_dir(1) -> tx.

