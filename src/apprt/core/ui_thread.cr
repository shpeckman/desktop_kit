# src/apprt/core/ui_thread.cr
require "sync/exclusive"

module Apprt
  # :nodoc:
  # The thread GTK runs on. GTK is not thread-safe: widgets, windows and the
  # application object are only touched there. Other threads hand work over
  # with `post`, which runs it at the next main loop iteration in posting
  # order. Blocks posted before the application runs wait for it; blocks still
  # queued when it stops are dropped.
  module UIThread
    @@thread = Atomic(Thread?).new(nil)
    @@queue = Sync::Exclusive(Deque(Proc(Nil))).new(Deque(Proc(Nil)).new)
    @@scheduled = Atomic(Bool).new(false)

    private DRAIN = ->(_data : Void*) { UIThread.drain; C::SOURCE_REMOVE }

    # Marks the calling thread as the UI thread for the duration of the block
    # and returns its value.
    def self.enter(&)
      @@thread.set(Thread.current)
      yield
    ensure
      @@queue.lock(&.clear)
      @@thread.set(nil)
    end

    def self.current? : Bool
      @@thread.get == Thread.current
    end

    # Raises `RuntimeError` unless called on the UI thread.
    def self.assert! : Nil
      raise RuntimeError.new("GTK called outside the UI thread") unless current?
    end

    def self.post(&block : ->) : Nil
      @@queue.lock(&.push(block))
      return if @@scheduled.swap(true)
      C.g_idle_add_full(C::PRIORITY_DEFAULT, DRAIN, nil, nil)
    end

    # Runs *block* now on the UI thread, posts it from other threads.
    def self.dispatch(&block : ->) : Nil
      if current?
        block.call
      else
        post(&block)
      end
    end

    protected def self.drain : Nil
      @@scheduled.set(false)
      batch = @@queue.lock do |queue|
        taken = queue.dup
        queue.clear
        taken
      end
      batch.each do |block|
        block.call
      rescue ex
        Log.error(exception: ex) { "posted block" }
      end
    end
  end
end
