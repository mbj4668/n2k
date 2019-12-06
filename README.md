# NMEA 2000 decoder

A standalone NMEA 2000 decoder in Erlang.  Decodes the following
formats:

- Yacht Device's RAW format
- Yacht Device's DAT format
- Yacht Device's CAN format
- CANBOAT's PLAIN format (CSV)

The program `n2k` can be used from the command line to convert or
pretty print files with NMEA 2000 frames or messages in one of the
supported formats.

The functions `n2k_raw:decode_raw/1` and `n2k_csv:decode_csv/1` can be
used to decode captured packets into NMEA 2000 frames.  The frames can
be decoded into messages by calling `n2k:decode_nmea/2`.

The NMEA message decoder is based on code from
https://github.com/tonyrog/nmea_2000.

NOTE: In order to build this code you need to place a copy of pgns.xml
with the pgns you want to be able to decode in src/.  E.g., from
canboat.
