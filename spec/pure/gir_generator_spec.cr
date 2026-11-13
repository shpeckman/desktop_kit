# spec/pure/gir_generator_spec.cr
require "../spec_helper"
require "../../tools/gir/generator"

private DATA = File.expand_path("../data", __DIR__)

private def generate(lines : String) : String
  repo = GirGenerator::Repository.new(DATA)
  ns = repo.load("Fixture-1.0")
  entries = GirGenerator.parse_allowlist(lines, "list.txt")
  gen = GirGenerator::Generator.new(repo, [{ns, entries}])
  String.build { |io| gen.emit(ns, io, "Spec", ["spec"]) }
end

private def fixture : String
  generate(File.read(File.join(DATA, "Fixture-1.0.txt")))
end

describe GirGenerator do
  it "parses allowlists, skipping comments and blank lines" do
    entries = GirGenerator.parse_allowlist("# head\n\na_b  # tail\n  c\n", "x.txt")
    entries.map(&.id).should eq ["a_b", "c"]
    entries.map(&.line).should eq [3, 4]
  end

  it "rejects two identifiers on one line" do
    expect_raises(GirGenerator::Error, "x.txt:1: more than one identifier") do
      GirGenerator.parse_allowlist("a b", "x.txt")
    end
  end

  it "wraps the namespace in a module and links its package" do
    out = fixture
    out.should start_with("# spec\nmodule Spec\n  # :nodoc:\n  @[Link(pkg_config: \"fixture-1\")]\n  lib C\n")
    out.should end_with("  end\nend\n")
    out.should_not contain("alias GType")
  end

  it "emits get-type functions, constructors and methods" do
    out = fixture
    out.should contain("    fun fix_thing_get_type : GType\n")
    out.should contain("    fun fix_thing_new(mode : FixMode) : Void*\n")
    out.should contain("    fun fix_thing_set_flags(thing : Void*, flags : FixFlags)\n")
    out.should contain("    fun fix_mode_to_string(mode : FixMode) : UInt8*\n")
  end

  it "maps out parameters with and without a c:type, and listed records by name" do
    fixture.should contain("    fun fix_thing_get_size(thing : Void*, width : Int32*, height : Int32*, point : FixPoint*)\n")
    fixture.should contain("    fun fix_list(p : FixPoint*)\n")
  end

  it "resolves GIR names without a c:type and renames keywords" do
    fixture.should contain("    fun fix_thing_get_mode(thing : Void*, end_ : Void*) : FixMode\n")
  end

  it "maps arrays, varargs, errors, callbacks, aliases and foreign pointers" do
    out = fixture
    out.should contain("    fun fix_strv(items : UInt8**, names : UInt8**) : Int32\n")
    out.should contain("    fun fix_log(format : UInt8*, ...)\n")
    out.should contain("    fun fix_load(path : UInt8*, error : Void**) : Int32\n")
    out.should contain("    fun fix_each(func : FixFunc, data : Void*, done : FixNotify)\n")
    out.should contain("    fun fix_id : UInt32\n")
    out.should contain("    fun fix_opaque_get(foreign : Void*) : Void*\n")
  end

  it "pulls in the enums, bitfields and callbacks listed symbols use" do
    out = fixture
    out.should contain("    enum FixMode : Int32\n      Off = 0\n      On = 1\n      Invalid = -1\n      N2d = 2\n    end\n")
    out.should contain("    @[Flags]\n    enum FixFlags : UInt32\n      FirstBit = 1\n      SecondBit = 2\n      High = 2147483648\n    end\n")
    out.should contain("    alias FixFunc = Int32, Void* -> Int32\n")
    out.should contain("    alias FixNotify = -> Void\n")
  end

  it "widens enums with values beyond Int32" do
    fixture.should contain("    enum FixBig : UInt32\n      Small = 1\n      Huge = 4294967295\n    end\n")
  end

  it "emits listed records as structs" do
    fixture.should contain(<<-CR)
          struct FixPoint
            x : Int32
            end_ : Float64
            func : FixFunc
            inline_cb : Void*
            padding : Void*[4]
          end

      CR
  end

  it "orders enums, callbacks, structs, then functions in allowlist order" do
    out = fixture
    enum_at = out.index!("enum FixMode")
    alias_at = out.index!("alias FixFunc")
    struct_at = out.index!("struct FixPoint")
    fun_at = out.index!("fun fix_thing_get_type")
    (enum_at < alias_at < struct_at < fun_at).should be_true
    out.index!("fun fix_thing_new").should be < out.index!("fun fix_list")
  end

  it "skips function-inline entries" do
    expect_raises(GirGenerator::Error, "list.txt:1: unknown symbol fix_inline") { generate("fix_inline") }
  end

  it "reports unknown symbols with file and line" do
    expect_raises(GirGenerator::Error, "list.txt:2: unknown symbol fix_nope") { generate("fix_id\nfix_nope") }
  end

  it "refuses records passed by value unless listed" do
    expect_raises(GirGenerator::Error, "FixOpaque passed by value") { generate("fix_by_value") }
  end

  it "refuses opaque, bit-field and union records" do
    expect_raises(GirGenerator::Error, "FixOpaque: opaque record") { generate("FixOpaque") }
    expect_raises(GirGenerator::Error, "FixPacked.bit: bit field") { generate("FixPacked") }
    expect_raises(GirGenerator::Error, "FixValue: has a union member") { generate("FixValue") }
  end

  it "refuses classes without a get-type function" do
    expect_raises(GirGenerator::Error, "list.txt:1: FixBase has no get-type function") { generate("FixBase") }
  end
end
