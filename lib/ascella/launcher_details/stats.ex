defmodule Ascella.LauncherDetails.Stats do
  @moduledoc """
  What `GET /_launcher/stats` answers: the JSON documented in
  `docs/launcher-details.md`. Raw numbers for anything that wants to compute,
  and `summary` - the same numbers as label/value lines in words and units,
  English or Dutch - for anything that only wants to show them (the Windows
  launcher, `ascella.sh details`).

  Cheap by rule, because it is asked every two seconds for as long as
  somebody leaves a panel open: no process asked anything it could be slow
  to answer, and nothing that waits. Alnasl's version also times a database;
  Ascella has none, which makes this the shortest health check in the hall.
  The process scan for open pages reads one key of each process's
  dictionary, about a millisecond for the few thousand processes a desktop
  copy has.
  """

  alias Ascella.LauncherDetails

  @mb 1_048_576
  @doc "The whole answer, as a map ready for JSON. `lang` is \"en\" or \"nl\"."
  def collect(lang \\ "en") do
    lang = if lang == "nl", do: "nl", else: "en"
    memory = :erlang.memory()
    uptime_ms = :erlang.statistics(:wall_clock) |> elem(0)

    stats = %{
      app: "ascella",
      version: vsn(:ascella),
      uptime_s: div(uptime_ms, 1000),
      started_at:
        DateTime.utc_now(:second) |> DateTime.add(-div(uptime_ms, 1000)) |> DateTime.to_iso8601(),
      system: system(),
      beam: %{
        memory_bytes: %{
          total: memory[:total],
          processes: memory[:processes],
          ets: memory[:ets],
          binary: memory[:binary],
          code: memory[:code]
        },
        processes: :erlang.system_info(:process_count),
        schedulers: :erlang.system_info(:schedulers_online),
        run_queue: :erlang.statistics(:run_queue),
        cpu_percent: LauncherDetails.cpu_percent()
      },
      log: log(),
      # The data folder in the JSON, not in the summary: the summary gets
      # pasted into mails, and a path names the user it belongs to.
      ascella: %{
        live_views: live_views(),
        data_dir: data_dir()
      }
    }

    Map.put(stats, :summary, summary(stats, lang))
  end

  # --- the parts --------------------------------------------------------------

  defp vsn(app) do
    case Application.spec(app, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  defp system do
    {family, name} = :os.type()

    os =
      case {family, name} do
        {:win32, _} -> "windows"
        {:unix, :darwin} -> "macos"
        {:unix, other} -> to_string(other)
      end

    %{
      os: os,
      os_version: :os.version() |> Tuple.to_list() |> Enum.join("."),
      arch: to_string(:erlang.system_info(:system_architecture)),
      cores: :erlang.system_info(:logical_processors_available) |> integer_or_nil(),
      otp: to_string(:erlang.system_info(:otp_release)),
      elixir: System.version(),
      load_average: load_average()
    }
  end

  defp integer_or_nil(n) when is_integer(n), do: n
  defp integer_or_nil(_unknown), do: nil

  # Linux only, and only because it is a file read: os_mon would answer for
  # every system, at the price of an application and a port program.
  defp load_average do
    with {:ok, text} <- File.read("/proc/loadavg"),
         [one, five, fifteen | _] <- String.split(text),
         {one, _} <- Float.parse(one),
         {five, _} <- Float.parse(five),
         {fifteen, _} <- Float.parse(fifteen) do
      [one, five, fifteen]
    else
      _none -> nil
    end
  end

  defp log do
    data = data_dir()

    cond do
      System.get_env(LauncherDetails.env_var()) not in [nil, ""] and is_binary(data) and
          File.exists?(Path.join(data, "launcher.log")) ->
        %{source: "file", path: Path.join(data, "launcher.log")}

      System.get_env("INVOCATION_ID") not in [nil, ""] ->
        %{source: "journald", unit: systemd_unit()}

      true ->
        %{source: "stdout"}
    end
  end

  defp data_dir do
    case Application.get_env(:ascella, :data_dir) do
      path when is_binary(path) -> path
      _none -> nil
    end
  end

  # "0::/system.slice/ascella.service" -> "ascella.service".
  defp systemd_unit do
    with {:ok, text} <- File.read("/proc/self/cgroup"),
         [unit | _] <- Regex.run(~r/[^\/\s]+\.service/, text) do
      unit
    else
      _none -> nil
    end
  end

  # Pages open: LiveView processes, which Phoenix labels with the view's mount
  # as their initial call. One dictionary key per process, nothing copied.
  defp live_views do
    Enum.count(Process.list(), fn pid ->
      match?(
        {{:dictionary, :"$initial_call"}, {_view, :mount, 3}},
        :erlang.process_info(pid, {:dictionary, :"$initial_call"})
      )
    end)
  end

  # --- in words -----------------------------------------------------------------

  @labels %{
    "en" => %{
      version: "Version",
      uptime: "Running for",
      cpu: "CPU",
      memory: "Memory",
      system: "System",
      pages: "Pages open"
    },
    "nl" => %{
      version: "Versie",
      uptime: "Draait al",
      cpu: "Processor",
      memory: "Geheugen",
      system: "Systeem",
      pages: "Open pagina's"
    }
  }

  @doc "The label of each summary line, in order, for a language - what a launcher shows before the server answers."
  def labels(lang \\ "en") do
    l = @labels[lang] || @labels["en"]

    [l.version, l.uptime, l.cpu, l.memory, l.system, l.pages]
  end

  defp summary(s, lang) do
    l = @labels[lang]
    nl? = lang == "nl"
    beam = s.beam
    mem = beam.memory_bytes
    app = s.ascella

    version = "Ascella #{s.version}"

    cpu =
      [
        if(beam.cpu_percent, do: "#{num(beam.cpu_percent, 1, nl?)} %", else: "—"),
        "(#{beam.schedulers} schedulers, #{if nl?, do: "wachtrij", else: "run queue"} #{beam.run_queue})",
        s.system.load_average &&
          "load " <> Enum.map_join(s.system.load_average, " ", &num(&1, 2, nl?))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    memory =
      "#{mb(mem.total, nl?)} (#{if nl?, do: "processen", else: "processes"} #{mb(mem.processes, nl?)}, " <>
        "ETS #{mb(mem.ets, nl?)}, binary #{mb(mem.binary, nl?)}; " <>
        "#{beam.processes} #{if nl?, do: "processen", else: "processes"})"

    sys = s.system

    system =
      "#{os_name(sys.os)} #{sys.os_version}, #{sys.arch}, " <>
        "#{if sys.cores, do: "#{sys.cores} #{if nl?, do: "kernen", else: "cores"}, ", else: ""}" <>
        "OTP #{sys.otp}"

    [
      [l.version, version],
      [l.uptime, duration(s.uptime_s, nl?)],
      [l.cpu, cpu],
      [l.memory, memory],
      [l.system, system],
      [l.pages, to_string(app.live_views)]
    ]
    |> Enum.map(fn [label, value] -> %{label: label, value: value} end)
  end

  defp os_name("windows"), do: "Windows"
  defp os_name("macos"), do: "macOS"
  defp os_name("linux"), do: "Linux"
  defp os_name(other), do: other

  defp mb(nil, _nl?), do: "—"
  defp mb(bytes, nl?), do: "#{num(bytes / @mb, 1, nl?)} MB"

  defp num(value, decimals, nl?) do
    text = :erlang.float_to_binary(value / 1, decimals: decimals)
    if nl?, do: String.replace(text, ".", ","), else: text
  end

  defp duration(seconds, _nl?) do
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3600)
    minutes = div(rem(seconds, 3600), 60)

    cond do
      days > 0 -> "#{days} d #{hours} h"
      hours > 0 -> "#{hours} h #{minutes} min"
      minutes > 0 -> "#{minutes} min"
      true -> "#{seconds} s"
    end
  end
end
