# spec/pure/variant_spec.cr
require "../spec_helper"

private enum Direction
  Up
  DownRight
end

private def round_trip(value : T) : T forall T
  DesktopKit::Variant.new(value).get(T)
end

describe DesktopKit::Variant do
  it "maps Crystal types to GVariant types" do
    {
      DesktopKit::Variant.signature(Bool)                                                    => "b",
      DesktopKit::Variant.signature(Int32)                                                   => "i",
      DesktopKit::Variant.signature(UInt32)                                                  => "u",
      DesktopKit::Variant.signature(Int64)                                                   => "x",
      DesktopKit::Variant.signature(UInt64)                                                  => "t",
      DesktopKit::Variant.signature(Float64)                                                 => "d",
      DesktopKit::Variant.signature(String)                                                  => "s",
      DesktopKit::Variant.signature(DesktopKit::Variant::ObjectPath)                         => "o",
      DesktopKit::Variant.signature(DesktopKit::Variant)                                     => "v",
      DesktopKit::Variant.signature(Direction)                                               => "s",
      DesktopKit::Variant.signature(Int32?)                                                  => "mi",
      DesktopKit::Variant.signature(Array(String))                                           => "as",
      DesktopKit::Variant.signature(Hash(String, DesktopKit::Variant))                       => "a{sv}",
      DesktopKit::Variant.signature(Tuple(String, Array(Int64), Bool?))                      => "(saxmb)",
      DesktopKit::Variant.signature(Array(Tuple(String, Hash(String, DesktopKit::Variant)))) => "a(sa{sv})",
    }.each { |actual, expected| actual.should eq expected }
  end

  it "round-trips scalars" do
    round_trip(true).should be_true
    round_trip(-7).should eq -7
    round_trip(7_u32).should eq 7_u32
    round_trip(Int64::MIN).should eq Int64::MIN
    round_trip(UInt64::MAX).should eq UInt64::MAX
    round_trip(2.5).should eq 2.5
    round_trip("héllo").should eq "héllo"
    round_trip(DesktopKit::Variant::ObjectPath.new("/org/example/App")).path.should eq "/org/example/App"
  end

  it "stores enums as snake case member names" do
    variant = DesktopKit::Variant.new(Direction::DownRight)
    variant.to_s.should eq "'down_right'"
    variant.get(Direction).should eq Direction::DownRight
    expect_raises(ArgumentError) { DesktopKit::Variant.new("sideways").get(Direction) }
  end

  it "round-trips containers" do
    round_trip(%w(a b c)).should eq %w(a b c)
    round_trip([] of String).should be_empty
    round_trip([1_i64, 2_i64]).should eq [1_i64, 2_i64]
    round_trip([] of Int32).should be_empty
    round_trip({"a" => 1, "b" => 2}).should eq({"a" => 1, "b" => 2})
    round_trip({"x", 3, [true, false]}).should eq({"x", 3, [true, false]})
    round_trip([{"n", 1}, {"m", 2}]).should eq [{"n", 1}, {"m", 2}]
  end

  it "round-trips maybe values" do
    round_trip(5.as(Int32?)).should eq 5
    round_trip(nil.as(Int32?)).should be_nil
    DesktopKit::Variant.new(nil.as(String?)).type_string.should eq "ms"
  end

  it "boxes variants and unboxes dictionary values" do
    options = DesktopKit::Variant.new({"modal" => DesktopKit::Variant.new(true), "title" => DesktopKit::Variant.new("Hi")})
    options.type_string.should eq "a{sv}"
    hash = options.get(Hash(String, DesktopKit::Variant))
    hash["modal"].get(Bool).should be_true
    hash["title"].get(String).should eq "Hi"
    options["title"]?.try(&.get(String)).should eq "Hi"
    options["missing"]?.should be_nil
  end

  it "indexes containers" do
    variant = DesktopKit::Variant.new({"a", 1})
    variant.size.should eq 2
    variant[0].get(String).should eq "a"
    variant[1].get(Int32).should eq 1
    expect_raises(IndexError) { variant[2] }
  end

  it "checks types" do
    variant = DesktopKit::Variant.new(1)
    variant.is?(Int32).should be_true
    variant.is?(String).should be_false
    expect_raises(TypeCastError, "cast from Variant(i) to String failed") { variant.get(String) }
  end

  it "parses the text format" do
    DesktopKit::Variant.parse("(1, 'a')").get(Tuple(Int32, String)).should eq({1, "a"})
    DesktopKit::Variant.parse("[1, 2]", "ax").get(Array(Int64)).should eq [1_i64, 2_i64]
    expect_raises(DesktopKit::GLibError) { DesktopKit::Variant.parse("(1,") }
  end

  it "compares by value and prints" do
    DesktopKit::Variant.new([1, 2]).should eq DesktopKit::Variant.new([1, 2])
    DesktopKit::Variant.new([1, 2]).should_not eq DesktopKit::Variant.new([2, 1])
    DesktopKit::Variant.new([1, 2]).hash.should eq DesktopKit::Variant.new([1, 2]).hash
    DesktopKit::Variant.new([1, 2]).to_s.should eq "[1, 2]"
    DesktopKit::Variant.new("a").inspect.should eq "Variant(s 'a')"
  end
end
