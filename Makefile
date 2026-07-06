SPCOMP?=spcomp64
OUTDIR?=build

SM:=$(OUTDIR)/addons/sourcemod

.PHONY: sm-ban-player-sprays
sm-ban-player-sprays: $(SM)/plugins/ban_player_sprays.smx
sm-ban-player-sprays: $(SM)/translations/ban_player_sprays.phrases.txt

SRCS := addons/sourcemod/scripting/ban_player_sprays.sp

$(SM)/plugins/ban_player_sprays.smx: $(SRCS)
	$(SPCOMP) "--output=$@" "$<" --warnings-as-errors

$(SM)/translations/ban_player_sprays.phrases.txt: addons/sourcemod/translations/ban_player_sprays.phrases.txt
	cp "$<" "$@"
