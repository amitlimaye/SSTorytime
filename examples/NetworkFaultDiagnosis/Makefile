BINARY := ../../cmd/bin/N4L
EVENTS ?= sustained egress queue drops,inter rack probe loss

all: $(BINARY)
	$(BINARY) -u -wipe fault-model.n4l layers/*.n4l incidents/*.n4l

# Rank probable causes from an anomaly report, e.g.
#   make diagnose EVENTS="routing adjacency reset,transceiver receive power"
diagnose:
	psql -d sstoryline -v events="'$(EVENTS)'" -f queries/probable-cause.sql

# Which faults can the current playbook library never surface?
blindspots:
	psql -d sstoryline -f queries/blind-spots.sql

check: $(BINARY)
	$(BINARY) fault-model.n4l layers/*.n4l incidents/*.n4l

$(BINARY):
	@echo "Binary $(BINARY) not found. Building from project root ..."
	$(MAKE) -C ../../.

clean:
	rm -f *_test_log *~
