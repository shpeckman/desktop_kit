# spec/gtk/desktop/notifications_spec.cr
require "./fake_notifications"

private def application_name : String
  Apprt::Native.string?(Apprt::C.g_get_application_name) || ""
end

# Opens a window split in two and returns its surfaces once the second has
# the focus.
private def split_window(app : TestApp) : {Apprt::Window, Apprt::Surface, Apprt::Surface}
  window = app.new_window
  first = window.active_surface.not_nil!
  second = first.split(:right)
  eventually { second.focused? }.should be_true
  {window, first, second}
end

describe Apprt::Surface do
  before_all { GtkHarness.start }

  it "sends a notification and presents the surface when it is clicked" do
    run_steps(TestApp.new) do |app|
      FakeNotifications.serve(app) do |fake|
        window = app.new_window
        first = window.active_surface.not_nil!
        other = window.new_tab.active_surface.not_nil!
        eventually { other.focused? }.should be_true

        first.notify("Build", "finished")
        eventually { fake.sent.size == 1 }.should be_true
        sent = fake.sent.first
        {sent.summary, sent.body, sent.replaces_id}.should eq({"Build", "finished", 0})
        sent.actions.should contain("default")

        fake.click(sent.id)
        eventually { first.focused? }.should be_true
        window.active_tab.should eq first.tab
      end
    end
  end

  it "titles a notification without a title by the application name" do
    run_steps(TestApp.new) do |app|
      FakeNotifications.serve(app) do |fake|
        _, first, _ = split_window(app)
        first.notify("", "done")
        eventually { fake.sent.size == 1 }.should be_true
        fake.sent.first.summary.should eq application_name
      end
    end
  end

  it "replaces a notification sent again" do
    run_steps(TestApp.new) do |app|
      FakeNotifications.serve(app) do |fake|
        _, first, _ = split_window(app)
        first.notify("Build", "finished")
        eventually { fake.sent.size == 1 }.should be_true
        settle
        first.notify("Build", "finished")
        eventually { fake.sent.size == 2 }.should be_true
        fake.sent.last.replaces_id.should eq fake.sent.first.id
      end
    end
  end

  it "withdraws its notifications once it gets the focus" do
    run_steps(TestApp.new) do |app|
      FakeNotifications.serve(app) do |fake|
        _, first, _ = split_window(app)
        first.notify("one", "")
        first.notify("two", "")
        eventually { fake.sent.size == 2 }.should be_true
        settle
        fake.closed.should be_empty
        first.focus
        eventually { fake.closed.size == 2 }.should be_true
        fake.closed.sort.should eq fake.sent.map(&.id).sort
      end
    end
  end

  it "withdraws a notification sent while focused after a timeout" do
    run_steps(TestApp.new) do |app|
      FakeNotifications.serve(app) do |fake|
        _, _, second = split_window(app)
        second.@notifications.timeout = 300.milliseconds
        second.notify("Build", "finished")
        eventually { fake.sent.size == 1 }.should be_true
        fake.closed.should be_empty
        eventually { fake.closed == [fake.sent.first.id] }.should be_true
      end
    end
  end

  it "withdraws its notifications when it closes" do
    run_steps(TestApp.new) do |app|
      FakeNotifications.serve(app) do |fake|
        _, first, _ = split_window(app)
        first.notify("Build", "finished")
        eventually { fake.sent.size == 1 }.should be_true
        settle
        first.close
        eventually { fake.closed == [fake.sent.first.id] }.should be_true
        first.notify("ignored", "")
        settle
        fake.sent.size.should eq 1
      end
    end
  end

  it "presents itself on the present-surface action" do
    run_steps(TestApp.new) do |app|
      window = app.new_window
      first = window.active_surface.not_nil!
      other = window.new_tab.active_surface.not_nil!
      eventually { other.focused? }.should be_true
      trigger(window, Apprt::Action::PresentSurface.new(first.id))
      eventually { first.focused? }.should be_true
      window.active_tab.should eq first.tab
      trigger(window, Apprt::Action::PresentSurface.new(0))
      first.focused?.should be_true
    end
  end
end

describe Apprt::App do
  before_all { GtkHarness.start }

  it "sends notifications of its own, by method and by action" do
    run_steps(TestApp.new) do |app|
      FakeNotifications.serve(app) do |fake|
        window = app.new_window
        surface = window.active_surface.not_nil!
        eventually { surface.focused? }.should be_true
        app.notify("Hello", "from the app")
        trigger(window, Apprt::Action::DesktopNotification.new("Done", "Build passed"))
        eventually { fake.sent.size == 2 }.should be_true
        fake.sent.map { |sent| {sent.summary, sent.body} }.should eq [{"Hello", "from the app"}, {"Done", "Build passed"}]
        fake.click(fake.sent.last.id)
        settle
        app.windows.size.should eq 1
        surface.focused?.should be_true
      end
    end
  end

  it "raises off the GTK thread" do
    expect_raises(RuntimeError, "GTK called outside the UI thread") { TestApp.new.notify("a", "b") }
  end
end
