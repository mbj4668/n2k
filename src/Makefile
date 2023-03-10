VSN = 1.0.0-beta.1

MODULES = n2k n2k_pgn n2k_raw n2k_csv n2k_can n2k_dat n2k_script

BEAM = $(MODULES:%=../ebin/%.beam)

BEHAVIOR_BEAMS = n2k_pgn_callback.beam

# all | none | <integer>,<integer>,...
# set this to control code generation of manufacturer proprietary PGNs
MANUFACTURER_CODES = all

# Include used-defined extra rules
-include ../system-config.mk

CUSTOM_PGNS = $(wildcard $(CUSTOM_DIR)/*-pgns.xml)

CUSTOM_MODULES = $(basename $(notdir $(wildcard $(CUSTOM_DIR)/*.erl)))

MODULES += $(CUSTOM_MODULES)

BEAM += $(addsuffix .beam,$(addprefix ../ebin/,$(CUSTOM_MODULES)))

PGNS_XML = canboat.xml $(CUSTOM_PGNS)

all: $(BEAM) ../ebin/n2k.app

APPSCRIPT = '$$vsn=shift; $$mods=""; while(@ARGV){ \
	$$_=shift; s/^([A-Z].*)$$/\'\''$$1\'\''/; \
	$$mods.=", " if $$mods; $$mods .= $$_; } \
	while(<>) { s/%VSN%/$$vsn/; s/%MODULES%/$$mods/; print; }'

# syntax w/ | below means that ../ebin is an order-only-prerequisite, which
# means the beam isn't rebuilt every time ../bin changes
../ebin/%.beam: $(CUSTOM_DIR)/%.erl $(BEHAVIOR_BEAMS) | ../ebin
	erlc -pa . -o ../ebin $<

../ebin/%.beam: %.erl $(BEHAVIOR_BEAMS) | ../ebin
	erlc -pa . -o ../ebin $<

../ebin/%.app: %.app.src Makefile | ../ebin
	perl -e $(APPSCRIPT) "$(VSN)" $(MODULES) < $< > $@

n2k_pgn.erl: pgns.term gen_n2k_pgn.beam
	erl -noshell -run gen_n2k_pgn gen $< $@

pgns.term: gen_pgns_term.beam $(PGNS_XML)
	erl -noshell -run gen_pgns_term gen $(MANUFACTURER_CODES) $@ $(PGNS_XML)

%.beam: %.erl
	erlc $<

../ebin:
	mkdir $@

clean:
	rm -rf *.beam pgns.term ../ebin n2k_pgn.erl
