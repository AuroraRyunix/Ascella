# The machine every test that does not bring its own runs on: a folder in
# tmp/, a Windows that is not there. Ascella.Apps and the page ask it what is
# installed; it never answers with this computer's real programs.
machine = Path.expand("../tmp/test-machine", __DIR__)
File.rm_rf!(machine)
Application.put_env(:ascella, :context, Ascella.FakeMachine.context(machine, :windows))

ExUnit.start()
