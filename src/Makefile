VSN = 0.1.0

MODULES = n2k n2k_pgn n2k_raw n2k_csv n2k_can n2k_dat

BEAM = $(MODULES:%=../ebin/%.beam)

all: $(BEAM) ../ebin/n2k.app

APPSCRIPT = '$$vsn=shift; $$mods=""; while(@ARGV){ \
	$$_=shift; s/^([A-Z].*)$$/\'\''$$1\'\''/; \
	$$mods.=", " if $$mods; $$mods .= $$_; } \
	while(<>) { s/%VSN%/$$vsn/; s/%MODULES%/$$mods/; print; }'

# syntax w/ | below means that ../ebin is an order-only-prerequisite, which
# means the beam isn't rebuilt every time ../bin changes
../ebin/%.beam: %.erl | ../ebin
	erlc -o ../ebin $<

../ebin/%.app: %.app.src Makefile | ../ebin
	perl -e $(APPSCRIPT) "$(VSN)" $(MODULES) < $< > $@

n2k_pgn.erl: pgns.term gen_n2k_pgn.beam
	erl -noshell -run gen_n2k_pgn gen $< $@

pgns.term: pgns.xml gen_pgns_term.beam
	erl -noshell -run gen_pgns_term gen $< $@

%.beam: %.erl
	erlc $<

../ebin:
	mkdir $@

clean:
	rm -rf *.beam pgns.term ../ebin n2k_pgn.erl
