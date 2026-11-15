# src/apprt/core/source.cr
module Apprt
  # A callback on the GTK thread's main loop: a timer from `App#after` or a
  # file descriptor watch from `App#watch`.
  #
  # A source stays active until it fires (timers), until `#cancel` or until
  # the application quits. Use it on the GTK thread only.
  class Source
    # Conditions of a watched file descriptor.
    @[Flags]
    enum Condition : UInt32
      # Data to read.
      Read = 1
      # Urgent data to read.
      Priority = 2
      # Room to write.
      Write = 4
      # An error.
      Error = 8
      # The other end hung up.
      HangUp = 16
      # The descriptor is not open.
      Invalid = 32
    end

    private TIMER = ->(data : Void*) do
      Handles.get(data, Source).fire(Condition::None)
      C::SOURCE_REMOVE
    end

    private WATCH = ->(_fd : Int32, condition : C::GIOCondition, data : Void*) do
      source = Handles.get(data, Source)
      condition = Condition.new(condition.value)
      source.fire(condition)
      source.active? && !condition.invalid? ? C::SOURCE_CONTINUE : C::SOURCE_REMOVE
    end

    private REMOVED = ->(data : Void*) do
      Handles.get(data, Source).removed
      Handles.release(data)
    end

    @@active = Set(Source).new

    @id = 0_u32

    private def initialize(@callback : Proc(Condition, Nil))
    end

    protected def self.timer(delay : Time::Span, &block : ->) : Source
      source = new(->(_condition : Condition) { block.call })
      milliseconds = delay.total_milliseconds.clamp(0, UInt32::MAX).to_u32
      source.start(C.g_timeout_add_full(C::PRIORITY_DEFAULT, milliseconds, TIMER, Handles.retain(source), REMOVED))
    end

    protected def self.watch(fd : Int32, conditions : Condition, &block : Condition ->) : Source
      source = new(block)
      flags = C::GIOCondition.new(conditions.value)
      source.start(C.g_unix_fd_add_full(C::PRIORITY_DEFAULT, fd, flags, WATCH, Handles.retain(source), REMOVED))
    end

    # Cancels every active source; the application calls it when it quits.
    protected def self.cancel_all : Nil
      @@active.dup.each(&.cancel)
    end

    # Whether the source can still fire.
    def active? : Bool
      @id != 0
    end

    # Stops the source; does nothing once it is no longer active.
    def cancel : Nil
      id = @id
      return if id == 0
      removed
      C.g_source_remove(id)
    end

    protected def start(id : UInt32) : self
      @id = id
      @@active << self
      self
    end

    protected def fire(condition : Condition) : Nil
      @callback.call(condition)
    rescue ex
      Log.error(exception: ex) { "source callback" }
    end

    protected def removed : Nil
      @id = 0_u32
      @@active.delete(self)
    end
  end
end
