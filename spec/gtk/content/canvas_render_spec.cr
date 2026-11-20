# spec/gtk/content/canvas_render_spec.cr
require "../harness"
require "json"

@[Link("GL")]
lib LibSpecGL
  COLOR_BUFFER_BIT = 0x4000_u32
  SCISSOR_TEST     = 0x0C11_u32

  fun glClearColor(red : Float32, green : Float32, blue : Float32, alpha : Float32)
  fun glClear(mask : UInt32)
  fun glEnable(cap : UInt32)
  fun glDisable(cap : UInt32)
  fun glScissor(x : Int32, y : Int32, width : Int32, height : Int32)
end

# Canvas that clears its upper half (in GL coordinates) red and the lower
# half blue, and records buffer ages and frame timings.
class HalvesCanvas < Apprt::Canvas
  getter ages = [] of Int32
  getter timings = [] of Apprt::FrameTiming
  getter threads = [] of String?

  protected def on_render : Nil
    @threads << Thread.current.name
    @ages << buffer_age
    LibSpecGL.glClearColor(1.0, 0.0, 0.0, 1.0)
    LibSpecGL.glClear(LibSpecGL::COLOR_BUFFER_BIT)
    LibSpecGL.glEnable(LibSpecGL::SCISSOR_TEST)
    LibSpecGL.glScissor(0, 0, width, height // 2)
    LibSpecGL.glClearColor(0.0, 0.0, 1.0, 1.0)
    LibSpecGL.glClear(LibSpecGL::COLOR_BUFFER_BIT)
    LibSpecGL.glDisable(LibSpecGL::SCISSOR_TEST)
  end

  protected def on_presented(timing : Apprt::FrameTiming) : Nil
    @timings << timing
  end
end

private def halves_app(offload : Bool = false, threaded : Bool = false) : TestApp
  TestApp.new.tap do |app|
    app.make_content = ->(context : Apprt::SurfaceContext) { HalvesCanvas.new(offload: offload, threaded: threaded).as(Apprt::Content) }
  end
end

private def halves(app : TestApp) : HalvesCanvas
  canvas = app.new_window.active_surface.not_nil!.content.as(HalvesCanvas)
  eventually { canvas.ages.size > 0 }.should be_true
  canvas
end

# Returns the mean rows of the screen's pure red and pure blue pixels,
# from a `grim` shot of the headless output.
private def red_and_blue_rows : {Float64, Float64}?
  shot = IO::Memory.new
  return unless Process.run("grim", ["-t", "ppm", "-"], output: shot, error: :close).success?
  bytes = shot.to_slice
  header = [] of String
  offset = 0
  while header.size < 4
    while bytes[offset].unsafe_chr.whitespace?
      offset += 1
    end
    start = offset
    until bytes[offset].unsafe_chr.whitespace?
      offset += 1
    end
    header << String.new(bytes[start, offset - start])
  end
  offset += 1
  width = header[1].to_i
  red = blue = 0.0
  reds = blues = 0
  pixels = bytes[offset..]
  (pixels.size // 3).times do |index|
    r, g, b = pixels[index * 3], pixels[index * 3 + 1], pixels[index * 3 + 2]
    next unless g == 0
    row = (index // width).to_f
    if r == 255 && b == 0
      red += row
      reds += 1
    elsif r == 0 && b == 255
      blue += row
      blues += 1
    end
  end
  {red / reds, blue / blues} if reds > 1000 && blues > 1000
end

# Runs a sway command through the harness's IPC socket and returns its
# output.
private def swaymsg(*args : String) : String
  dir = ENV["XDG_RUNTIME_DIR"]
  socket = Dir.children(dir).find(&.starts_with?("sway-ipc.")).not_nil!
  output = IO::Memory.new
  Process.run("swaymsg", ["-s", "#{dir}/#{socket}", *args], output: output, error: :inherit).success?.should be_true
  output.to_s
end

# Adds a second headless output at *scale*, focuses it so new windows open
# there, yields and removes it. GDK does not lower a monitor's scale again
# once it rose, so the specs leave the first output's scale alone.
private def with_scaled_output(scale : Number, &) : Nil
  before = JSON.parse(swaymsg("-t", "get_outputs", "-r")).as_a.map(&.["name"].as_s)
  swaymsg("create_output")
  name = JSON.parse(swaymsg("-t", "get_outputs", "-r")).as_a.map(&.["name"].as_s).find { |output| !before.includes?(output) }.not_nil!
  begin
    swaymsg("output", name, "resolution", "1280x800", "scale", scale.to_s)
    swaymsg("focus", "output", name)
    yield
  ensure
    swaymsg("focus", "output", "HEADLESS-1")
    swaymsg("output", name, "unplug")
  end
end

describe "Canvas rendering" do
  before_all { GtkHarness.start }

  it "shows its frames with the GL origin at the bottom" do
    run_steps(halves_app) do |app|
      halves(app)
      rows = nil.as({Float64, Float64}?)
      eventually { settle(50.milliseconds); !(rows = red_and_blue_rows).nil? }.should be_true
      red, blue = rows.not_nil!
      red.should be < blue
    end
  end

  it "offloads its frames as DMA-BUFs the right way up" do
    run_steps(halves_app(offload: true)) do |app|
      canvas = halves(app)
      eventually { canvas.dmabuf? }.should be_true
      rows = nil.as({Float64, Float64}?)
      eventually { settle(50.milliseconds); !(rows = red_and_blue_rows).nil? }.should be_true
      red, blue = rows.not_nil!
      red.should be < blue
    end
  end

  it "renders on its own thread when threaded" do
    run_steps(halves_app(threaded: true)) do |app|
      canvas = halves(app)
      canvas.threaded?.should be_true
      rows = nil.as({Float64, Float64}?)
      eventually { settle(50.milliseconds); !(rows = red_and_blue_rows).nil? }.should be_true
      red, blue = rows.not_nil!
      red.should be < blue
      3.times do
        count = canvas.ages.size
        canvas.queue_render
        eventually { canvas.ages.size > count }.should be_true
      end
      canvas.threads.uniq.should eq ["canvas"]
      canvas.ages.last.should be > 0
      eventually { canvas.timings.size > 0 }.should be_true
    end
  end

  it "offloads frames of a threaded canvas" do
    run_steps(halves_app(offload: true, threaded: true)) do |app|
      canvas = halves(app)
      eventually { canvas.dmabuf? }.should be_true
    end
  end

  it "stops the render thread when the canvas goes" do
    run_steps(halves_app(threaded: true)) do |app|
      window = app.new_window
      canvas = window.active_surface.not_nil!.content.as(HalvesCanvas)
      eventually { canvas.ages.size > 0 }.should be_true
      window.close
      eventually { window.closed? }.should be_true
      settle
      canvas.gl_context.should be_nil
    end
  end

  it "sends GL textures without offload" do
    run_steps(halves_app) do |app|
      canvas = halves(app)
      settle
      canvas.dmabuf?.should be_false
    end
  end

  it "tells the age of each buffer and when frames were shown" do
    run_steps(halves_app) do |app|
      canvas = halves(app)
      canvas.ages.first.should eq 0
      4.times do
        count = canvas.ages.size
        canvas.queue_render
        eventually { canvas.ages.size > count }.should be_true
      end
      canvas.ages.last.should be > 0
      eventually { canvas.timings.size > 0 }.should be_true
      timing = canvas.timings.first
      timing.frame.should be <= canvas.frame
      timing.presented.try(&.should be > Time::Span.zero)
    end
  end

  it "draws at the exact size of a fractional scale" do
    with_scaled_output(1.5) do
      run_steps(halves_app) do |app|
        canvas = halves(app)
        eventually do
          canvas.scale == 1.5 && canvas.width == (canvas.widget.width * 1.5).round.to_i &&
            canvas.height == (canvas.widget.height * 1.5).round.to_i
        end.should be_true
      end
    end
  end

  it "makes offscreen contexts" do
    run_steps(TestApp.new) do
      context = Apprt::GLContext.new(version: {3, 0})
      context.api.none?.should be_false
      context.make_current
      context.current?.should be_true
      Apprt::GLContext.clear_current
      context.current?.should be_false
    end
  end
end
