# This file is part of the Luau programming language and is licensed under MIT License; see LICENSE.txt for details
MAKEFLAGS+=-r -j8
COMMA=,

config=debug

BUILD=build/$(config)

AST_SOURCES=$(wildcard Ast/src/*.cpp)
AST_OBJECTS=$(AST_SOURCES:%=$(BUILD)/%.o)
AST_TARGET=$(BUILD)/libluauast.a

COMPILER_SOURCES=$(wildcard Compiler/src/*.cpp)
COMPILER_OBJECTS=$(COMPILER_SOURCES:%=$(BUILD)/%.o)
COMPILER_TARGET=$(BUILD)/libluaucompiler.a

ANALYSIS_SOURCES=$(wildcard Analysis/src/*.cpp)
ANALYSIS_OBJECTS=$(ANALYSIS_SOURCES:%=$(BUILD)/%.o)
ANALYSIS_TARGET=$(BUILD)/libluauanalysis.a

VM_SOURCES=$(wildcard VM/src/*.cpp)
VM_OBJECTS=$(VM_SOURCES:%=$(BUILD)/%.o)
VM_TARGET=$(BUILD)/libluauvm.a

TESTS_SOURCES=$(wildcard tests/*.cpp)
TESTS_OBJECTS=$(TESTS_SOURCES:%=$(BUILD)/%.o)
TESTS_TARGET=$(BUILD)/luau-tests

REPL_CLI_SOURCES=CLI/FileUtils.cpp CLI/Profiler.cpp CLI/Repl.cpp
REPL_CLI_OBJECTS=$(REPL_CLI_SOURCES:%=$(BUILD)/%.o)
REPL_CLI_TARGET=$(BUILD)/luau

ANALYZE_CLI_SOURCES=CLI/FileUtils.cpp CLI/Analyze.cpp
ANALYZE_CLI_OBJECTS=$(ANALYZE_CLI_SOURCES:%=$(BUILD)/%.o)
ANALYZE_CLI_TARGET=$(BUILD)/luau-analyze

FUZZ_SOURCES=$(wildcard fuzz/*.cpp)
FUZZ_OBJECTS=$(FUZZ_SOURCES:%=$(BUILD)/%.o)

TESTS_ARGS=
ifneq ($(flags),)
	TESTS_ARGS+=--fflags=$(flags)
endif

OBJECTS=$(AST_OBJECTS) $(COMPILER_OBJECTS) $(ANALYSIS_OBJECTS) $(VM_OBJECTS) $(TESTS_OBJECTS) $(CLI_OBJECTS) $(FUZZ_OBJECTS)

# common flags
CXXFLAGS=-g -Wall -Werror
LDFLAGS=

CXXFLAGS+=-Wno-unused # temporary, for older gcc versions

# configuration-specific flags
ifeq ($(config),release)
	CXXFLAGS+=-O2 -DNDEBUG
endif

ifeq ($(config),coverage)
	CXXFLAGS+=-fprofile-instr-generate -fcoverage-mapping
	LDFLAGS+=-fprofile-instr-generate
endif

ifeq ($(config),sanitize)
	CXXFLAGS+=-fsanitize=address -O1
	LDFLAGS+=-fsanitize=address
endif

ifeq ($(config),analyze)
	CXXFLAGS+=--analyze
endif

ifeq ($(config),fuzz)
	CXX=clang++ # our fuzzing infra relies on llvm fuzzer
	CXXFLAGS+=-fsanitize=address,fuzzer -Ibuild/libprotobuf-mutator -Ibuild/libprotobuf-mutator/external.protobuf/include -O2
	LDFLAGS+=-fsanitize=address,fuzzer
endif

# target-specific flags
$(AST_OBJECTS): CXXFLAGS+=-std=c++17 -IAst/include
$(COMPILER_OBJECTS): CXXFLAGS+=-std=c++17 -ICompiler/include -IAst/include
$(ANALYSIS_OBJECTS): CXXFLAGS+=-std=c++17 -IAst/include -IAnalysis/include
$(VM_OBJECTS): CXXFLAGS+=-std=c++11 -IVM/include
$(TESTS_OBJECTS): CXXFLAGS+=-std=c++17 -IAst/include -ICompiler/include -IAnalysis/include -IVM/include -Iextern
$(REPL_CLI_OBJECTS): CXXFLAGS+=-std=c++17 -IAst/include -ICompiler/include -IVM/include -Iextern
$(ANALYZE_CLI_OBJECTS): CXXFLAGS+=-std=c++17 -IAst/include -IAnalysis/include -Iextern
$(FUZZ_OBJECTS): CXXFLAGS+=-std=c++17 -IAst/include -ICompiler/include -IAnalysis/include -IVM/include

$(REPL_CLI_TARGET): LDFLAGS+=-lpthread
fuzz-proto fuzz-prototest: LDFLAGS+=build/libprotobuf-mutator/src/libfuzzer/libprotobuf-mutator-libfuzzer.a build/libprotobuf-mutator/src/libprotobuf-mutator.a build/libprotobuf-mutator/external.protobuf/lib/libprotobuf.a

# pseudo targets
.PHONY: all test clean coverage format luau-size

all: $(REPL_CLI_TARGET) $(ANALYZE_CLI_TARGET) $(TESTS_TARGET)

test: $(TESTS_TARGET)
	$(TESTS_TARGET) $(TESTS_ARGS)

clean:
	rm -rf $(BUILD)

coverage: $(TESTS_TARGET)
	$(TESTS_TARGET) --fflags=true
	mv default.profraw default-flags.profraw
	$(TESTS_TARGET)
	llvm-profdata merge default.profraw default-flags.profraw -o default.profdata
	rm default.profraw default-flags.profraw
	llvm-cov show -format=html -show-instantiations=false -show-line-counts=true -show-region-summary=false -ignore-filename-regex=\(tests\|extern\)/.* -output-dir=coverage --instr-profile default.profdata build/coverage/luau-tests
	llvm-cov report -ignore-filename-regex=\(tests\|extern\)/.* -show-region-summary=false --instr-profile default.profdata build/coverage/luau-tests
	llvm-cov export -ignore-filename-regex=\(tests\|extern\)/.* -format lcov --instr-profile default.profdata build/coverage/luau-tests >coverage.info

format:
	find . -name '*.h' -or -name '*.cpp' | xargs clang-format -i

luau-size: luau
	nm --print-size --demangle luau | grep ' t void luau_execute<false>' | awk -F ' ' '{sum += strtonum("0x" $$2)} END {print sum " interpreter" }'
	nm --print-size --demangle luau | grep ' t luauF_' | awk -F ' ' '{sum += strtonum("0x" $$2)} END {print sum " builtins" }'

# executable target aliases
luau: $(REPL_CLI_TARGET)
	cp $^ $@

luau-analyze: $(ANALYZE_CLI_TARGET)
	cp $^ $@

# executable targets
$(TESTS_TARGET): $(TESTS_OBJECTS) $(ANALYSIS_TARGET) $(COMPILER_TARGET) $(AST_TARGET) $(VM_TARGET)
$(REPL_CLI_TARGET): $(REPL_CLI_OBJECTS) $(COMPILER_TARGET) $(AST_TARGET) $(VM_TARGET)
$(ANALYZE_CLI_TARGET): $(ANALYZE_CLI_OBJECTS) $(ANALYSIS_TARGET) $(AST_TARGET)

$(TESTS_TARGET) $(REPL_CLI_TARGET) $(ANALYZE_CLI_TARGET):
	$(CXX) $^ $(LDFLAGS) -o $@

# executable targets for fuzzing
fuzz-%: $(BUILD)/fuzz/%.cpp.o $(ANALYSIS_TARGET) $(COMPILER_TARGET) $(AST_TARGET) $(VM_TARGET)
fuzz-proto: $(BUILD)/fuzz/proto.cpp.o $(BUILD)/fuzz/protoprint.cpp.o $(BUILD)/fuzz/luau.pb.cpp.o $(ANALYSIS_TARGET) $(COMPILER_TARGET) $(AST_TARGET) $(VM_TARGET) | build/libprotobuf-mutator
fuzz-prototest: $(BUILD)/fuzz/prototest.cpp.o $(BUILD)/fuzz/protoprint.cpp.o $(BUILD)/fuzz/luau.pb.cpp.o $(ANALYSIS_TARGET) $(COMPILER_TARGET) $(AST_TARGET) $(VM_TARGET) | build/libprotobuf-mutator

fuzz-%:
	$(CXX) $^ $(LDFLAGS) -o $@

# static library targets
$(AST_TARGET): $(AST_OBJECTS)
$(COMPILER_TARGET): $(COMPILER_OBJECTS)
$(ANALYSIS_TARGET): $(ANALYSIS_OBJECTS)
$(VM_TARGET): $(VM_OBJECTS)

$(AST_TARGET) $(COMPILER_TARGET) $(ANALYSIS_TARGET) $(VM_TARGET):
	ar rcs $@ $^

# object file targets
$(BUILD)/%.cpp.o: %.cpp
	@mkdir -p $(dir $@)
	$(CXX) $< $(CXXFLAGS) -c -MMD -MP -o $@

# protobuf fuzzer setup
fuzz/luau.pb.cpp: fuzz/luau.proto build/libprotobuf-mutator
	cd fuzz && ../build/libprotobuf-mutator/external.protobuf/bin/protoc luau.proto --cpp_out=.
	mv fuzz/luau.pb.cc fuzz/luau.pb.cpp

$(BUILD)/fuzz/proto.cpp.o: build/libprotobuf-mutator
$(BUILD)/fuzz/protoprint.cpp.o: build/libprotobuf-mutator

build/libprotobuf-mutator:
	git clone https://github.com/google/libprotobuf-mutator build/libprotobuf-mutator
	CXX= cmake -S build/libprotobuf-mutator -B build/libprotobuf-mutator -D CMAKE_BUILD_TYPE=Release -D LIB_PROTO_MUTATOR_DOWNLOAD_PROTOBUF=ON -D LIB_PROTO_MUTATOR_TESTING=OFF
	make -C build/libprotobuf-mutator -j8

# picks up include dependencies for all object files
-include $(OBJECTS:.o=.d)
