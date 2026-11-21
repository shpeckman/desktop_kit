# src/desktop_kit/content/render_thread.cr
require "sync/exclusive"

module DesktopKit
  # A thread that draws threaded canvases (`Canvas.new(threaded: thread)`)
  # with one GL context.
  #
  # The canvases on one thread draw one after another and share every GL
  # object made in their hooks: programs, textures and caches made once
  # serve them all, and GL state set by one hook is what the next one
  # finds. The thread starts when the first of its canvases is realized and
  # ends when the last one is unrealized; GL objects meant to outlive a
  # canvas die with the thread's context then. A canvas moved to another
  # place in the window (a split, a tab) unrealizes and realizes again in
  # one main loop iteration, so the thread keeps running across the move.
  #
  # ```
  # thread = DesktopKit::RenderThread.new(version: {4, 3})
  # left = MyCanvas.new(threaded: thread)
  # right = MyCanvas.new(threaded: thread)
  # ```
  class RenderThread
    # Returns the name of the thread.
    getter name : String

    @api : Canvas::API
    @version : {Int32, Int32}?
    @queue = Sync::Exclusive(Deque(Proc(Nil))).new(Deque(Proc(Nil)).new)
    @wake = Channel(Nil).new(1)
    @renderer : Fiber::ExecutionContext::Isolated?
    @context : GLContext?
    @owner : GLContext?
    @canvases = 0
    # The idle source that stops the thread once no canvas came back.
    @stopping = 0_u32
    # Set on the thread by the stop job; cleared once it ended.
    @stopped = false

    # Creates the thread, named *name*. Its GL context is one of *api*'s
    # flavours that offers at least *version* (`{major, minor}`); the
    # *api* and *version* of its canvases are not used.
    def initialize(*, api : Canvas::API = Canvas::API::All, version : {Int32, Int32}? = nil,
                   @name : String = "canvas")
      @api = api
      @version = version
    end

    # Returns whether the thread runs: while one of its canvases is
    # realized.
    def running? : Bool
      !@renderer.nil?
    end

    # Starts the thread for one more canvas when none ran, and returns the
    # thread's context and the GTK thread's context its frames name.
    # Raises `GLibError` when the display has no such context.
    protected def attach : {GLContext, GLContext}
      unless @stopping == 0
        Idle.cancel(@stopping)
        @stopping = 0_u32
      end
      context = @context
      owner = @owner
      unless context && owner
        # Owner: see `Canvas#start_renderer`.
        owner = GLContext.new(api: @api, version: @version)
        context = GLContext.new(api: @api, version: @version)
        @context = context
        @owner = owner
        @renderer = Fiber::ExecutionContext::Isolated.new(@name) { serve(context) }
      end
      @canvases += 1
      {context, owner}
    end

    # Runs *job* on the thread with its context current, after the jobs
    # posted before. Never blocks; *job* must not raise.
    protected def post(&job : ->) : Nil
      @queue.lock(&.push(job))
      select
      when @wake.send(nil)
      else
      end
    end

    # Runs *job* on the thread, waits until it ran and counts one canvas
    # less; the last one stops the thread once the main loop is idle,
    # unless a canvas attached again by then.
    protected def detach(&job : ->) : Nil
      done = Channel(Nil).new(1)
      post do
        job.call
      ensure
        done.send(nil)
      end
      done.receive
      @canvases -= 1
      return unless @canvases == 0 && @stopping == 0
      @stopping = Idle.add do
        @stopping = 0_u32
        stop if @canvases == 0
      end
    end

    # Runs *job* on the thread when it runs with *context* current, and
    # returns whether it will. Call on the GTK thread, which also stops the
    # thread: a job taken here runs before the thread ends.
    protected def dispose(context : GLContext, &job : ->) : Bool
      return false unless @renderer && @context.same?(context)
      post(&job)
      true
    end

    private def stop : Nil
      renderer = @renderer || return
      post { @stopped = true }
      renderer.wait
    ensure
      @renderer = nil
      @context = nil
      @owner = nil
      @stopped = false
    end

    private def serve(context : GLContext) : Nil
      context.make_current
      until @stopped
        @wake.receive
        jobs = @queue.lock do |queue|
          taken = queue.dup
          queue.clear
          taken
        end
        jobs.each(&.call)
      end
    ensure
      GLContext.clear_current
    end
  end
end
