BINARY := ../../cmd/bin/N4L

all: $(BINARY)
	$(BINARY) -u -wipe drift-model.n4l incidents/*.n4l

# The reference model on its own, without the worked incidents. Useful when
# loading your own incident files against the vocabulary.
model: $(BINARY)
	$(BINARY) -u -wipe drift-model.n4l

# Parse and validate without touching the database contents.
check: $(BINARY)
	$(BINARY) drift-model.n4l incident-template.n4l incidents/*.n4l

# Ingestion lint. Every check should return zero rows.
lint:
	psql -d sstoryline -f queries/lint-ingestion.sql

$(BINARY):
	@echo "Binary $(BINARY) not found. Building from project root ..."
	$(MAKE) -C ../../.

clean:
	rm -f *_test_log *~
