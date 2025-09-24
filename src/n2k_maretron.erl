-module(n2k_maretron).
-export([
    tank_meter_get_depth/2,
    compass_start_calibration/2,
    compass_resend_calibration_status/2,
    compass_recv_calibration_status/2,
    compass_calibrate_installation_offset/3,
    compass_start_rate_of_turn_zeroing/2,
    compass_cancel_rate_of_turn_zeroing/2,
    compass_set_rate_of_turn_dampening/3
]).

-define(MARETRON_VENDOR_AND_CODE, 16#9889).

-define(TLM_100_PROD_CODE, 27725).
-define(TLM_100_SW_CODE, 1).

-define(SSC300_PROD_CODE, 2686).
-define(SSC300_SW_CODE, 1).

-define(START_CALIBRATION_COMMAND, 16#F0).
-define(CALIBRATION_SUCCEEDED, 1).
-define(CALIBRATION_FAILED, 2).
-define(RESEND_CALIBRATION_STATUS_COMMAND, 16#50).
-define(INSTALLATION_OFFSET_COMMAND, 16#24).
-define(RATE_OF_TURN_CONFIGURATION_COMMAND, 16#5E).
-define(RATE_OF_TURN_SET_DAMPENING, 2).
-define(RATE_OF_TURN_INITIATE_ZEROING, 17).
-define(RATE_OF_TURN_CANCEL_ZEROING, 18).

%% Call compass_recv_calibration_status/2 to get progress and calibration status.
%% erlfmt:ignore
compass_start_calibration(Transport, Dst) ->
    Data =
        nmea_command_group_function_data(
            126720, 4,
            <<1, ?MARETRON_VENDOR_AND_CODE:16/little-unsigned,
              2, ?SSC300_PROD_CODE:16/little-unsigned,
              3, ?SSC300_SW_CODE:16/little-unsigned,
              ?START_CALIBRATION_COMMAND>>),
    CanId = {_Pri = 4, 126208, _Src = 95, Dst},
    n2k_transport:send_fast(Transport, n2k:encode_nmea_fast_message(CanId, Data, _Order = 1)).

%% erlfmt:ignore
%% Call compass_recv_calibration_status/2 to get progress and calibration status.
compass_resend_calibration_status(Transport, Dst) ->
    Data =
        nmea_command_group_function_data(
            126720, 4,
            <<1, ?MARETRON_VENDOR_AND_CODE:16/little-unsigned,
              2, ?SSC300_PROD_CODE:16/little-unsigned,
              3, ?SSC300_SW_CODE:16/little-unsigned,
              ?RESEND_CALIBRATION_STATUS_COMMAND>>),
    CanId = {_Pri = 4, 126208, _Src = 95, Dst},
    n2k_transport:send_fast(Transport, n2k:encode_nmea_fast_message(CanId, Data, _Order = 1)).

-spec compass_resend_calibration_status(
    n2k_transport:transport(),
    fun(({status, integer()} | {error, {pgnErrorCode, atom()}}) -> any())
) ->
    ok | error.
compass_recv_calibration_status(Tr, F) ->
    n2k_transport:recv(
        Tr, {message, [126208, 126720], ignore}, fun compass_recv_calibration_status_handler/2, F
    ).

compass_recv_calibration_status_handler(Msg, F) ->
    case Msg of
        {message, {_Time, _CanId, {maretronDeviationCalibrationStatus, Fields}}} ->
            [_, _, _, _, _, {status, Status}] = Fields,
            F({status, Status}),
            if
                Status == ?CALIBRATION_SUCCEEDED ->
                    {done, ok};
                Status == ?CALIBRATION_FAILED ->
                    {done, error};
                true ->
                    F
            end;
        {message, {_Time, _CanId, {nmeaAcknowledgeGroupFunction, Fields}}} ->
            [_, _, {pgnErrorCode, PGNErrorCode} | _] = Fields,
            case PGNErrorCode of
                0 ->
                    %% no error
                    F;
                _ ->
                    F({error, {pgnErrorCode, pgn_error(PGNErrorCode)}}),
                    {done, error}
            end;
        _ ->
            F
    end.

%% erlfmt:ignore
compass_calibrate_installation_offset(Transport, Dst, Heading) ->
    Data =
        nmea_command_group_function_data(
            126720, 4,
            <<1, ?MARETRON_VENDOR_AND_CODE:16/little-unsigned,
              2, ?SSC300_PROD_CODE:16/little-unsigned,
              3, ?SSC300_SW_CODE:16/little-unsigned,
              ?INSTALLATION_OFFSET_COMMAND,
              Heading:16/little-unsigned>>),
    CanId = {_Pri = 4, 126208, _Src = 95, Dst},
    n2k_transport:send_fast(Transport, n2k:encode_nmea_fast_message(CanId, Data, _Order = 1)),
    recv_nmea_acknowledge_group_function(Transport).

-spec compass_start_rate_of_turn_zeroing(n2k_transport:transport(), integer()) ->
    ok | {error, {pgnErrorCode, PGNError :: atom()}}.
%% erlfmt:ignore
compass_start_rate_of_turn_zeroing(Transport, Dst) ->
    Data =
        nmea_command_group_function_data(
            126720, 4,
            <<1, ?MARETRON_VENDOR_AND_CODE:16/little-unsigned,
              2, ?SSC300_PROD_CODE:16/little-unsigned,
              3, ?SSC300_SW_CODE:16/little-unsigned,
              ?RATE_OF_TURN_CONFIGURATION_COMMAND,
              ?RATE_OF_TURN_INITIATE_ZEROING>>),
    CanId = {_Pri = 4, 126208, _Src = 95, Dst},
    n2k_transport:send_fast(Transport, n2k:encode_nmea_fast_message(CanId, Data, _Order = 1)),
    recv_nmea_acknowledge_group_function(Transport).

-spec compass_cancel_rate_of_turn_zeroing(n2k_transport:transport(), integer()) ->
    ok | {error, {pgnErrorCode, PGNErrorCode :: atom()}}.
%% erlfmt:ignore
compass_cancel_rate_of_turn_zeroing(Transport, Dst) ->
    Data =
        nmea_command_group_function_data(
            126720, 4,
            <<1, ?MARETRON_VENDOR_AND_CODE:16/little-unsigned,
              2, ?SSC300_PROD_CODE:16/little-unsigned,
              3, ?SSC300_SW_CODE:16/little-unsigned,
              ?RATE_OF_TURN_CONFIGURATION_COMMAND,
              ?RATE_OF_TURN_CANCEL_ZEROING>>),
    CanId = {_Pri = 4, 126208, _Src = 95, Dst},
    n2k_transport:send_fast(Transport, n2k:encode_nmea_fast_message(CanId, Data, _Order = 1)),
    recv_nmea_acknowledge_group_function(Transport).

-spec compass_set_rate_of_turn_dampening(n2k_transport:transport(), integer(), integer()) ->
    ok | {error, {pgnErrorCode, PGNErrorCode :: atom()}}.
%% erlfmt:ignore
compass_set_rate_of_turn_dampening(Transport, Dst, PeriodMs) ->
    Data =
        nmea_command_group_function_data(
            126720, 4,
            <<1, ?MARETRON_VENDOR_AND_CODE:16/little-unsigned,
              2, ?SSC300_PROD_CODE:16/little-unsigned,
              3, ?SSC300_SW_CODE:16/little-unsigned,
              ?RATE_OF_TURN_CONFIGURATION_COMMAND,
              ?RATE_OF_TURN_SET_DAMPENING,
              PeriodMs:16/little-unsigned>>),
    CanId = {_Pri = 4, 126208, _Src = 95, Dst},
    n2k_transport:send_fast(Transport, n2k:encode_nmea_fast_message(CanId, Data, _Order = 1)),
    recv_nmea_acknowledge_group_function(Transport).

tank_meter_get_depth(_Transport, _Device) ->
    %    {CanIdInt, Frames} = nmeaCommandGroupFunction(_Prio = 4, Device, _Order = 1),
    %   n2k_request:fast_send_and_receive(
    %       Proto, Address, Port, CanIdInt, Message, fun get_depth_raw_line/2, []
    %   ),
    %   ok.
    nyi.

%% %% FIXME: on timeout, re-send, abort after N attempts.
%% get_depth_raw_line(Line, S) when is_binary(Line) ->
%%     {Frame, _Dir} = n2k_raw:decode_raw(Line),
%%     {_Time, {_Pri, PGN, Src, _Dst}, _Data} = Frame,
%%     if
%%         PGN == 126720 andalso Src == S#get_depth.dev ->
%%             case n2k:decode_nmea(Frame, S#get_depth.n2k_state) of
%%                 {true, Msg, _N2kState1} ->
%%                     {done, Msg};
%%                 {false, N2kState1} ->
%%                     S#get_depth{n2k_state = N2kState1};
%%                 {error, _, N2kState1} ->
%%                     S#get_depth{n2k_state = N2kState1}
%%             end;
%%         true ->
%%             S
%%     end.

%% nmea_request_group_function_data(
%%     RequestedPGN, TransmissionInterval, TransmissionIntervalOffset, NParams, Params
%% ) ->
%%     <<0:8, RequestedPGNPGN:24/little-unsigned, TransmissionInterval:32/little-unsigned,
%%         TransmissionIntervalOffset:16/little-unsigned, NParams:8, Params/binary>>.

nmea_command_group_function_data(CommandedPGN, NParams, Params) ->
    Priority = 16#8,
    <<1:8, CommandedPGN:24/little-unsigned, 16#F:4, Priority:4, NParams:8, Params/binary>>.

recv_nmea_acknowledge_group_function(Tr) ->
    n2k_transport:recv(
        Tr, {message, [126208], ignore}, fun recv_nmea_acknowledge_group_function_handler/2, []
    ).

recv_nmea_acknowledge_group_function_handler(Msg, _State) ->
    case Msg of
        {message, {_Time, _CanId, {nmeaAcknowledgeGroupFunction, Fields}}} ->
            [_, _, {pgnErrorCode, PGNErrorCode} | _] = Fields,
            case PGNErrorCode of
                0 ->
                    {done, ok};
                _ ->
                    {done, {error, {pgnErrorCode, pgn_error(PGNErrorCode)}}}
            end;
        _ ->
            []
    end.

pgn_error(ErrorCode) ->
    case ErrorCode of
        0 -> ok;
        1 -> invalid_request;
        2 -> temporary_error;
        3 -> parameter_out_of_range;
        4 -> access_denied;
        5 -> not_supported;
        6 -> not_supported;
        _ -> unknown_error_code
    end.
