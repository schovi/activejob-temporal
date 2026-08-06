# frozen_string_literal: true

require "spec_helper"
require "listen"
require "activejob/temporal/listen_warning_filter"

describe ActiveJob::Temporal::ListenWarningFilter do
  def duplicate_watch_message(symlinked, real_path)
    format(Listen::Record::SymlinkDetector::SYMLINK_LOOP_ERROR, symlinked, real_path)
  end

  def atomic_writer_message
    duplicate_watch_message(
      "/run/secrets/tokens/..data",
      "/run/secrets/tokens/..2026_08_06_10_00_00.123456789"
    )
  end

  def with_clean_install
    previous_behavior = Listen.adapter_warn_behavior
    previously_installed = described_class.instance_variable_get(:@installed)
    described_class.instance_variable_set(:@installed, false)
    yield
  ensure
    Listen.adapter_warn_behavior = previous_behavior
    described_class.instance_variable_set(:@installed, previously_installed)
  end

  it "silences the duplicate-watch warning for kubelet atomic-writer volumes" do
    with_clean_install do
      Listen.adapter_warn_behavior = :warn
      described_class.install!

      assert_equal :silent, Listen.adapter_warn_behavior.call(atomic_writer_message)
      assert_silent { Listen.adapter_warn(atomic_writer_message) }
    end
  end

  it "keeps the previous behavior for duplicate-watch warnings outside atomic-writer volumes" do
    with_clean_install do
      Listen.adapter_warn_behavior = :log
      described_class.install!

      assert_equal :log, Listen.adapter_warn_behavior.call(duplicate_watch_message("/a/link", "/b/real"))
    end
  end

  it "delegates unrelated messages to a previously configured callable" do
    with_clean_install do
      seen = []
      Listen.adapter_warn_behavior = lambda do |message|
        seen << message
        :log
      end
      described_class.install!

      assert_equal :log, Listen.adapter_warn_behavior.call("inotify watch limit reached")
      assert_equal :silent, Listen.adapter_warn_behavior.call(atomic_writer_message)
      assert_equal ["inotify watch limit reached"], seen
    end
  end

  it "installs only once" do
    with_clean_install do
      Listen.adapter_warn_behavior = :warn
      described_class.install!
      installed_behavior = Listen.adapter_warn_behavior
      described_class.install!

      assert_same installed_behavior, Listen.adapter_warn_behavior
    end
  end
end
