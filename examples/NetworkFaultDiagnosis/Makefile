BINARY := ../../cmd/bin/N4L
SYMPTOMS ?= intermittent loss,average interface utilisation,batch job

all: $(BINARY)
	$(BINARY) -u -wipe fault-model.n4l layers/*.n4l incidents/*.n4l

# Rank probable causes from a comma separated symptom list, e.g.
#   make diagnose SYMPTOMS="adjacency flaps,blackholes in one direction"
diagnose:
	psql -d sstoryline -v symptoms="'$(SYMPTOMS)'" -f queries/probable-cause.sql

# Parse and validate without touching the database contents.
check: $(BINARY)
	$(BINARY) fault-model.n4l layers/*.n4l incidents/*.n4l

$(BINARY):
	@echo "Binary $(BINARY) not found. Building from project root ..."
	$(MAKE) -C ../../.

clean:
	rm -f *_test_log *~
