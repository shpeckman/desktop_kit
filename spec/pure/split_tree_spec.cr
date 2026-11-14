# spec/pure/split_tree_spec.cr
require "../spec_helper"

private alias Tree = Apprt::SplitTree(String)

private def handle(tree : Tree, view : String) : Int32
  tree.locate(view) || fail "#{view} not in tree"
end

private def lines(*rows : String) : String
  rows.join { |row| "#{row}\n" }
end

# A | B
private def ab : Tree
  Tree.new("A").split(Tree::ROOT, :right, "B")
end

# A | (B | (C | D))
private def abcd : Tree
  t3 = ab
  t4 = t3.split(handle(t3, "B"), :right, "C")
  t4.split(handle(t4, "C"), :right, "D")
end

# A over C on the left (0.8), B over D on the right (0.3).
private def grid : Tree
  tree = ab
  ac = tree.split(handle(tree, "A"), :down, "C", 0.8)
  ac.split(handle(ac, "B"), :down, "D", 0.3)
end

describe Apprt::SplitTree do
  it "tells splits from leaves" do
    Tree.new.split?.should be_false
    Tree.new("A").split?.should be_false
    ab.split?.should be_true
  end

  it "prints an empty tree" do
    tree = Tree.new
    tree.empty?.should be_true
    tree.to_s.should eq("empty")
    tree.to_diagram.should eq("empty")
    tree.spatial.should be_empty
  end

  it "prints a single leaf" do
    tree = Tree.new("A")
    tree.to_diagram.should eq(lines("+---+", "| A |", "+---+"))
    tree.to_s.should eq("leaf: A\n")
  end

  it "splits horizontally" do
    t3 = ab
    t3.to_diagram.should eq(lines("+---++---+", "| A || B |", "+---++---+"))
    t3.to_s.should eq(lines(
      "split (layout: horizontal, ratio: 0.50)",
      "  leaf: A",
      "  leaf: B"))

    t4 = t3.split(handle(t3, "B"), :right, "C")
    t4.to_diagram.should eq(lines(
      "+--------++---++---+",
      "|    A   || B || C |",
      "+--------++---++---+"))
    t4.to_s.should eq(lines(
      "split (layout: horizontal, ratio: 0.50)",
      "  leaf: A",
      "  split (layout: horizontal, ratio: 0.50)",
      "    leaf: B",
      "    leaf: C"))

    t5 = abcd
    t5.to_diagram.should eq(lines(
      "+------------------++--------++---++---+",
      "|         A        ||    B   || C || D |",
      "+------------------++--------++---++---+"))
    t5.to_s.should eq(lines(
      "split (layout: horizontal, ratio: 0.50)",
      "  leaf: A",
      "  split (layout: horizontal, ratio: 0.50)",
      "    leaf: B",
      "    split (layout: horizontal, ratio: 0.50)",
      "      leaf: C",
      "      leaf: D"))
  end

  it "moves to the previous and next leaf" do
    tree = abcd
    a, b, c, d = %w(A B C D).map { |view| handle(tree, view) }

    tree.goto(d, :previous).should eq(c)
    tree.goto(c, :previous).should eq(b)
    tree.goto(b, :previous).should eq(a)
    tree.goto(a, :previous).should be_nil

    tree.goto(a, :next).should eq(b)
    tree.goto(b, :next).should eq(c)
    tree.goto(c, :next).should eq(d)
    tree.goto(d, :next).should be_nil

    tree.goto(a, :previous_wrapped).should eq(d)
    tree.goto(d, :next_wrapped).should eq(a)
    tree.goto(b, :previous_wrapped).should eq(a)
  end

  it "splits vertically" do
    tree = Tree.new("A").split(Tree::ROOT, :down, "B")
    tree.to_diagram.should eq(lines("+---+", "| A |", "+---+", "+---+", "| B |", "+---+"))
    tree.to_s.should eq(lines(
      "split (layout: vertical, ratio: 0.50)",
      "  leaf: A",
      "  leaf: B"))
  end

  it "inserts left and up before the existing view" do
    left = Tree.new("A").split(Tree::ROOT, :left, "B")
    left.to_diagram.should eq(lines("+---++---+", "| B || A |", "+---++---+"))
    up = Tree.new("A").split(Tree::ROOT, :up, "B")
    up.to_diagram.should eq(lines("+---+", "| B |", "+---+", "+---+", "| A |", "+---+"))
  end

  it "hides leaves without space" do
    {Apprt::Direction::Right, Apprt::Direction::Down}.each do |direction|
      Tree.new("A").split(Tree::ROOT, direction, "B", 0.0)
        .to_diagram.should eq(lines("+---+", "| B |", "+---+"))
      Tree.new("A").split(Tree::ROOT, direction, "B", 1.0)
        .to_diagram.should eq(lines("+---+", "| A |", "+---+"))
    end
  end

  it "inserts a whole tree" do
    tree = Tree.new("A").split(Tree::ROOT, :right, ab)
    tree.map(&.last).should eq(%w(B A A))
    tree.to_s.should eq(lines(
      "split (layout: horizontal, ratio: 0.50)",
      "  leaf: A",
      "  split (layout: horizontal, ratio: 0.50)",
      "    leaf: A",
      "    leaf: B"))
  end

  it "removes a leaf" do
    tree = ab
    tree.remove(handle(tree, "A")).to_diagram.should eq(lines("+---+", "| B |", "+---+"))
    tree.remove(Tree::ROOT).empty?.should be_true
  end

  it "removes from a nested tree" do
    split1 = ab
    split2 = split1.split(Tree::ROOT, :down, "C")
    split2.to_diagram.should eq(lines(
      "+---++---+",
      "| A || B |",
      "+---++---+",
      "+--------+",
      "|    C   |",
      "+--------+"))

    removed = split2.remove(handle(split2, "B"))
    removed.to_diagram.should eq(lines("+---+", "| A |", "+---+", "+---+", "| C |", "+---+"))
    removed.node_count.should eq(3)

    split2.node_count.times { |at| split2.remove(at) }
  end

  it "moves across splits spatially" do
    tree = grid
    tree.to_diagram.should eq(lines(
      "+---++---+",
      "|   ||   |",
      "|   ||   |",
      "|   || B |",
      "|   ||   |",
      "|   |+---+",
      "| A |+---+",
      "|   ||   |",
      "|   ||   |",
      "|   ||   |",
      "|   || D |",
      "+---+|   |",
      "+---+|   |",
      "| C ||   |",
      "+---++---+"))
    a, b, c, d = %w(A B C D).map { |view| handle(tree, view) }

    tree.goto(c, Apprt::Direction::Right).should eq(d)
    tree.goto(d, Apprt::Direction::Left).should eq(a)
    tree.goto(a, Apprt::Direction::Left).should eq(b)
    tree.goto(b, Apprt::Direction::Right).should eq(a)
    tree.goto(c, Apprt::Direction::Down).should eq(a)
    Tree.new("A").goto(Tree::ROOT, Apprt::Direction::Up).should be_nil
  end

  it "equalizes by leaves along each axis" do
    grid.equalize.to_diagram.should eq(lines(
      "+---++---+",
      "| A || B |",
      "+---++---+",
      "+---++---+",
      "| C || D |",
      "+---++---+"))

    t4 = abcd.remove(handle(abcd, "D")).equalize
    t4.to_diagram.should eq(lines("+---++---++---+", "| A || B || C |", "+---++---++---+"))
    t4.to_s.should eq(lines(
      "split (layout: horizontal, ratio: 0.33)",
      "  leaf: A",
      "  split (layout: horizontal, ratio: 0.50)",
      "    leaf: B",
      "    leaf: C"))
  end

  it "resizes the nearest split along an axis" do
    tree = ab
    b = handle(tree, "B")
    tree.resize(b, :horizontal, 0.25).to_diagram.should eq(lines(
      "+-------------++---+",
      "|      A      || B |",
      "+-------------++---+"))
    tree.resize(b, :horizontal, -0.25).to_diagram.should eq(lines(
      "+---++-------------+",
      "| A ||      B      |",
      "+---++-------------+"))
    tree.resize(b, :vertical, 0.25).should eq(tree)
    Tree.new("A").resize(Tree::ROOT, :horizontal, 0.5).should eq(Tree.new("A"))
  end

  it "resizes nested splits relative to the whole tree" do
    split_ab = Tree.new("A").split(Tree::ROOT, :down, "B")
    tree = split_ab.split(handle(split_ab, "B"), :down, "C")
    tree.to_diagram.should eq(lines(
      "+---+", "|   |", "|   |", "| A |", "|   |", "+---+",
      "+---+", "| B |", "+---+",
      "+---+", "| C |", "+---+"))

    b = handle(tree, "B")
    tree.resize(b, :vertical, 0.125).to_diagram.should eq(lines(
      "+---+", "|   |", "|   |", "|   |", "|   |", "|   |", "| A |", "|   |", "|   |", "|   |", "|   |", "+---+",
      "+---+", "|   |", "|   |", "|   |", "| B |", "|   |", "|   |", "|   |", "+---+",
      "+---+", "| C |", "+---+"))
    tree.resize(b, :vertical, -0.0833).to_diagram.should eq(lines(
      "+---+", "|   |", "|   |", "|   |", "| A |", "|   |", "|   |", "|   |", "+---+",
      "+---+", "| B |", "+---+",
      "+---+", "|   |", "|   |", "| C |", "|   |", "+---+"))
  end

  it "replaces the ratio of a split" do
    tree = ab.with_ratio(Tree::ROOT, 0.25)
    tree[Tree::ROOT].as(Tree::Split).ratio.should eq(0.25)
    tree.to_s.should start_with("split (layout: horizontal, ratio: 0.25)")
  end

  it "computes slots on the unit square" do
    slots = grid.spatial
    tree = grid
    slots[Tree::ROOT].should eq(Tree::Slot.new(0.0, 0.0, 1.0, 1.0))
    a = slots[handle(tree, "A")]
    {a.x, a.y, a.width}.should eq({0.0, 0.0, 0.5})
    a.height.should be_close(0.8, 1e-9)
    d = slots[handle(tree, "D")]
    {d.x, d.width}.should eq({0.5, 0.5})
    d.y.should be_close(0.3, 1e-9)
    d.max_y.should be_close(1.0, 1e-9)
  end

  it "zooms a leaf" do
    tree = ab.zoom(handle(ab, "B"))
    tree.zoomed.should eq(handle(ab, "B"))
    tree.to_s.should eq(lines(
      "split (layout: horizontal, ratio: 0.50)",
      "  leaf: A",
      "  (zoomed) leaf: B"))
    tree.zoom(nil).zoomed.should be_nil
  end

  it "resets the zoom on split" do
    tree = Tree.new("A").zoom(Tree::ROOT)
    tree.to_s.should eq("(zoomed) leaf: A\n")
    tree.split(Tree::ROOT, :right, "B").zoomed.should be_nil
  end

  it "keeps the zoom across equalize and resize" do
    a = handle(ab, "A")
    tree = ab.zoom(a)
    tree.equalize.zoomed.should eq(a)
    tree.resize(handle(tree, "B"), :horizontal, 0.1).zoomed.should eq(a)
  end

  it "moves or clears the zoom on remove" do
    tree = ab.zoom(handle(ab, "A"))
    removed_zoomed = tree.remove(handle(tree, "A"))
    removed_zoomed.zoomed.should be_nil
    removed_zoomed.to_s.should eq("leaf: B\n")

    removed_other = tree.remove(handle(tree, "B"))
    removed_other.zoomed.should eq(Tree::ROOT)
    removed_other.to_s.should eq("(zoomed) leaf: A\n")
  end

  it "leaves the original tree unchanged" do
    tree = ab
    text = tree.to_s
    tree.split(handle(tree, "A"), :down, "C")
    tree.remove(handle(tree, "B"))
    tree.equalize
    tree.resize(handle(tree, "B"), :horizontal, 0.25)
    tree.with_ratio(Tree::ROOT, 0.1)
    tree.zoom(Tree::ROOT)
    tree.to_s.should eq(text)
  end

  it "looks up views and nodes" do
    tree = abcd
    tree.map(&.last).sort.should eq(%w(A B C D))
    tree.locate("E").should be_nil
    tree.view(handle(tree, "C")).should eq("C")
    tree[Tree::ROOT].should be_a(Tree::Split)
    tree.deepest(:left).should eq(handle(tree, "A"))
    tree.deepest(:right).should eq(handle(tree, "D"))
  end

  it "rejects invalid arguments" do
    tree = ab
    expect_raises(IndexError, "invalid split tree handle 3") { tree[3] }
    expect_raises(IndexError, "invalid split tree handle -1") { tree.goto(-1, :next) }
    expect_raises(IndexError) { Tree.new.remove(Tree::ROOT) }
    expect_raises(ArgumentError, "split tree node 0 is a split") { tree.view(Tree::ROOT) }
    expect_raises(ArgumentError, "split tree node 1 is a leaf") { tree.with_ratio(1, 0.5) }
    expect_raises(IndexError) { tree.zoom(3) }
    expect_raises(ArgumentError, "split ratio must be between 0 and 1, not 1.5") do
      tree.split(Tree::ROOT, :right, "C", 1.5)
    end
    expect_raises(ArgumentError, "cannot insert an empty split tree") do
      tree.split(Tree::ROOT, :right, Tree.new)
    end
    expect_raises(ArgumentError, "resize delta must be between -1 and 1, not 2.0") do
      tree.resize(handle(tree, "B"), :horizontal, 2.0)
    end
  end
end
