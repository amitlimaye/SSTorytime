BINARY := ../../cmd/bin/N4L
EVENTS ?= sustained egress queue drops,inter rack probe loss
HYP ?= ecmp hash polarisation

all: $(BINARY)
	$(BINARY) -u -wipe fault-model.n4l complaint-model.n4l layers/*.n4l incidents/*.n4l

# Rank probable causes from an anomaly report, e.g.
#   make diagnose EVENTS="routing adjacency reset,transceiver receive power"
diagnose:
	psql -d sstoryline -v events="'$(EVENTS)'" -f queries/probable-cause.sql

# Emit a guided debug script to prove or disprove one hypothesis, e.g.
#   make script HYP="mtu mismatch"
script:
	psql -d sstoryline -x -v hyp="'$(HYP)'" -f queries/debug-script.sql

# Which faults can the current playbook library never surface?
blindspots:
	psql -d sstoryline -f queries/blind-spots.sql

check: $(BINARY)
	$(BINARY) fault-model.n4l complaint-model.n4l layers/*.n4l incidents/*.n4l

$(BINARY):
	@echo "Binary $(BINARY) not found. Building from project root ..."
	$(MAKE) -C ../../.

clean:
	rm -f *_test_log *~
