SPCOMP?=spcomp64
OUTDIR?=build/

SCRIPTING:=addons/sourcemod/scripting/

$(OUTDIR)ban_player_sprays.spx: $(SCRIPTING)ban_player_sprays.sp
	$(SPCOMP) "--output=$@" "$<" \
		"--include=$(SCRIPTING)include" \
		"--include=../sm-multi-colors/$(SCRIPTING)include" \
		--warnings-as-errors
