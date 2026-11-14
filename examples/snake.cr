# examples/snake.cr
#
# A snake game on an OpenGL canvas, drawn with scissored clears. Steering
# uses physical keys, so WASD sits in the same place on every layout.
#
#   crystal run examples/snake.cr
#
# Space starts and pauses, WASD or the arrows steer, R restarts. Shift+Ctrl+O splits
# the window into a second, independent game.
require "../src/apprt"

@[Link("GL")]
lib LibGL
  COLOR_BUFFER_BIT = 0x4000_u32
  SCISSOR_TEST     = 0x0C11_u32

  fun glClearColor(red : Float32, green : Float32, blue : Float32, alpha : Float32)
  fun glClear(mask : UInt32)
  fun glEnable(cap : UInt32)
  fun glDisable(cap : UInt32)
  fun glScissor(x : Int32, y : Int32, width : Int32, height : Int32)
end

module Snake
  COLUMNS = 24
  ROWS    = 14
  TICK    = 125.milliseconds

  # The direction each steering key turns the snake.
  STEERING = {
    Apprt::Key::KeyW       => {0, -1},
    Apprt::Key::ArrowUp    => {0, -1},
    Apprt::Key::KeyS       => {0, 1},
    Apprt::Key::ArrowDown  => {0, 1},
    Apprt::Key::KeyA       => {-1, 0},
    Apprt::Key::ArrowLeft  => {-1, 0},
    Apprt::Key::KeyD       => {1, 0},
    Apprt::Key::ArrowRight => {1, 0},
  }

  # Red, green and blue of each thing on the board.
  COLORS = {
    board: {0.08, 0.09, 0.11},
    field: {0.12, 0.13, 0.16},
    snake: {0.20, 0.75, 0.30},
    head:  {0.45, 0.95, 0.50},
    food:  {0.95, 0.40, 0.40},
    dead:  {0.60, 0.15, 0.15},
  }

  # The state of one game: the snake from head to tail, its heading, the
  # food and the score.
  class Game
    getter snake = [] of {Int32, Int32}
    getter food = {0, 0}
    getter score = 0
    getter? over = false
    property? paused = false
    @heading = {1, 0}
    @turn = {1, 0}

    # Starts paused, so the snake waits for the player.
    def initialize
      restart
      @paused = true
    end

    def restart : Nil
      @snake = [{3, ROWS // 2}, {2, ROWS // 2}, {1, ROWS // 2}]
      @heading = @turn = {1, 0}
      @score = 0
      @over = false
      @paused = false
      place_food
    end

    # Turns the snake on its next step, unless that reverses it.
    def steer(direction : {Int32, Int32}) : Nil
      @turn = direction unless direction == {-@heading[0], -@heading[1]}
    end

    # Moves the snake one cell; returns whether anything changed.
    def step : Bool
      return false if @over || @paused
      @heading = @turn
      head = {@snake[0][0] + @heading[0], @snake[0][1] + @heading[1]}
      if !(0...COLUMNS).includes?(head[0]) || !(0...ROWS).includes?(head[1]) || @snake[0...-1].includes?(head)
        @over = true
        return true
      end
      @snake.unshift(head)
      if head == @food
        @score += 1
        place_food
      else
        @snake.pop
      end
      true
    end

    def status : String
      return "Game over · Score #{@score} · R restart" if @over
      return "Paused · Score #{@score} · Space resume" if @paused
      "Score #{@score}"
    end

    private def place_food : Nil
      free = (0...COLUMNS).flat_map { |x| (0...ROWS).map { |y| {x, y} } } - @snake
      @food = free.sample unless free.empty?
    end
  end

  # The canvas showing one game, which it steps on a timer while open.
  class Board < Apprt::Canvas
    @game = Game.new
    @status = ""

    def initialize(@app : Apprt::App)
      super(api: :gl)
    end

    # Steps the game every `TICK` from a fiber, posting each step to the
    # GTK thread, until the surface closes.
    def start : Nil
      sync_title
      spawn do
        until surface.closed?
          sleep TICK
          @app.post { changed if @game.step }
        end
      end
    end

    protected def on_render : Nil
      return if width == 0 || height == 0
      size = {width // (COLUMNS + 2), height // (ROWS + 2)}.min
      left = (width - size * COLUMNS) // 2
      bottom = (height - size * ROWS) // 2
      fill(COLORS[:board], 0, 0, width, height)
      fill(COLORS[:field], left, bottom, size * COLUMNS, size * ROWS)
      cell(COLORS[:food], @game.food, left, bottom, size)
      @game.snake.each_with_index do |part, index|
        color = @game.over? ? COLORS[:dead] : index == 0 ? COLORS[:head] : COLORS[:snake]
        cell(color, part, left, bottom, size)
      end
      LibGL.glDisable(LibGL::SCISSOR_TEST)
    end

    protected def on_key(event : Apprt::KeyEvent) : Bool
      return false unless event.pressed? && event.mods.none?
      if direction = STEERING[event.key]?
        @game.steer(direction)
      elsif event.key.space?
        @game.paused = !@game.paused? unless @game.over?
      elsif event.key.key_r?
        @game.restart
      else
        return false
      end
      changed
      true
    end

    # Clears the board cell at *at*, counted from the top left, to *color*.
    private def cell(color, at : {Int32, Int32}, left : Int32, bottom : Int32, size : Int32) : Nil
      fill(color, left + at[0] * size + 1, bottom + (ROWS - 1 - at[1]) * size + 1, size - 2, size - 2)
    end

    private def fill(color : {Float64, Float64, Float64}, x : Int32, y : Int32, w : Int32, h : Int32) : Nil
      LibGL.glEnable(LibGL::SCISSOR_TEST)
      LibGL.glScissor(x, y, w, h)
      LibGL.glClearColor(color[0].to_f32, color[1].to_f32, color[2].to_f32, 1.0_f32)
      LibGL.glClear(LibGL::COLOR_BUFFER_BIT)
    end

    private def changed : Nil
      queue_render
      sync_title
    end

    private def sync_title : Nil
      status = @game.status
      return if status == @status
      @status = status
      surface.title = "Snake · #{status}"
    end
  end

  class App < Apprt::App
    protected def new_surface(context : Apprt::SurfaceContext) : Apprt::Content
      board = Board.new(self)
      post { board.start }
      board
    end

    protected def on_startup : Nil
      self.window_style = Apprt::WindowStyle.new(pane_headers: true, cards: true, unfocused_opacity: 0.7)
      self.bindings = [
        Apprt::Binding.new("ctrl+shift+o", Apprt::Action::NewSplit.new(:right)),
        Apprt::Binding.new("ctrl+q", Apprt::Action::Quit.new),
      ]
    end

    protected def on_activate : Nil
      new_window
    end
  end
end

exit Snake::App.new("org.example.Snake").run
