# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec

defmodule Mix.CLI do
  @moduledoc false

  @doc """
  Runs Mix according to the command line arguments.
  """
  def main(args \\ System.argv()) do
    if env_variable_activated?("MIX_DEBUG") do
      IO.puts("-> Running mix CLI")
      {time, res} = :timer.tc(&main/2, [args, true])
      IO.puts(["<- Ran mix CLI in ", Integer.to_string(div(time, 1000)), "ms"])
      res
    else
      main(args, false)
    end
  end

  defp main(args, debug?) do
    Mix.start()

    if debug?, do: Mix.debug(true)
    if env_variable_activated?("MIX_QUIET"), do: Mix.shell(Mix.Shell.Quiet)

    if profile = System.get_env("MIX_PROFILE") do
      flags = System.get_env("MIX_PROFILE_FLAGS", "")
      {opts, args} = Mix.Tasks.Profile.Tprof.parse!(OptionParser.split(flags))

      if args != [] do
        Mix.raise("Invalid arguments given to MIX_PROFILE_FLAGS: #{inspect(args)}")
      end

      opts = Keyword.put_new(opts, :warmup, false)
      Mix.State.put(:profile, {opts, String.split(profile, ",")})
    end

    case check_for_shortcuts(args) do
      :help ->
        Mix.shell().info("Mix is a build tool for Elixir")
        display_usage()

      :version ->
        display_version()

      nil ->
        proceed(args)
    end
  end

  defp proceed(args) do
    load_dot_config()
    load_mix_exs(args)
    project = Mix.Project.get()
    {task, args} = get_task(args, project)
    ensure_hex(task)
    maybe_change_env_and_target(task, project)
    run_task(task, args)
  end

  defp load_mix_exs(args) do
    file = System.get_env("MIX_EXS") || "mix.exs"

    if File.regular?(file) do
      Mix.ProjectStack.post_config(state_loader: {:cli, List.first(args)})
      old_undefined = Code.get_compiler_option(:no_warn_undefined)
      Code.put_compiler_option(:no_warn_undefined, :all)
      Code.compile_file(file)
      Code.put_compiler_option(:no_warn_undefined, old_undefined)
    end
  end

  defp get_task(["-" <> _ | _], project) do
    task = "mix #{default_task(project)}"

    Mix.shell().error(
      "** (Mix) Mix only recognizes the options --help and --version.\n" <>
        "You may have wanted to invoke a task instead, such as #{inspect(task)}"
    )

    display_usage()
    exit({:shutdown, 1})
  end

  defp get_task([h | t], _project) do
    {h, t}
  end

  defp get_task([], nil) do
    Mix.shell().error(
      "** (Mix) \"mix\" with no arguments must be executed in a directory with a mix.exs file"
    )

    display_usage()
    exit({:shutdown, 1})
  end

  defp get_task([], project) do
    {default_task(project), []}
  end

  defp default_task(project) do
    cond do
      function_exported?(project, :cli, 0) ->
        project.cli()[:default_task] || "run"

      default_task = Mix.Project.config()[:default_task] ->
        IO.warn("""
        setting :default_task in your mix.exs \"def project\" is deprecated, set it inside \"def cli\" instead:

            def cli do
              [default_task: #{inspect(default_task)}]
            end
        """)

        default_task

      true ->
        "run"
    end
  end

  defp run_task(name, args) do
    try do
      ensure_no_slashes(name)
      # We must go through the task instead of invoking the
      # module directly because projects like Nerves alias it.
      Mix.Task.run("loadconfig")
      Mix.Task.run(name, args)
    rescue
      # We only rescue exceptions in the Mix namespace,
      # all others pass through and raise as usual.
      exception ->
        case {Mix.debug?(), Map.get(exception, :mix, false)} do
          {false, true} ->
            simplified_exception(exception, 1)

          {false, code} when code in 0..255 ->
            simplified_exception(exception, code)

          _ ->
            reraise exception, __STACKTRACE__
        end
    end
  end

  defp simplified_exception(%name{} = exception, code) do
    mod = name |> Module.split() |> hd()
    Mix.shell().error("** (#{mod}) #{Exception.message(exception)}")
    exit({:shutdown, code})
  end

  defp env_variable_activated?(name) do
    System.get_env(name) in ~w(1 true)
  end

  defp ensure_hex("local.hex"), do: :ok
  defp ensure_hex(_task), do: Mix.Hex.ensure_updated?()

  defp ensure_no_slashes(task) do
    if String.contains?(task, "/") do
      raise Mix.NoTaskError, task: task
    end
  end

  defp maybe_change_env_and_target(task, project) do
    task = String.to_atom(task)
    config = Mix.Project.config()

    env = preferred_cli_env(project, task, config)
    target = preferred_cli_target(project, task, config)
    env && Mix.env(env)
    target && Mix.target(target)

    if env || target do
      reload_project()
    end
  end

  defp preferred_cli_env(project, task, config) do
    if function_exported?(project, :cli, 0) || System.get_env("MIX_ENV") do
      nil
    else
      value = config[:preferred_cli_env]

      if value do
        IO.warn("""
        setting :preferred_cli_env in your mix.exs \"def project\" is deprecated, set it inside \"def cli\" instead:

            def cli do
              [preferred_envs: #{inspect(value)}]
            end
        """)
      end

      value[task] || preferred_cli_env(task)
    end
  end

  defp preferred_cli_target(project, task, config) do
    if function_exported?(project, :cli, 0) || System.get_env("MIX_TARGET") do
      nil
    else
      value = config[:preferred_cli_target]

      if value do
        IO.warn("""
        setting :preferred_cli_target in your mix.exs \"def project\" is deprecated, set it inside \"def cli\" instead:

            def cli do
              [preferred_targets: #{inspect(value)}]
            end
        """)
      end

      value[task]
    end
  end

  @doc """
  Available for backwards compatibility.
  """
  def preferred_cli_env(task) when is_atom(task) or is_binary(task) do
    case Mix.Task.get(task) do
      nil ->
        nil

      module ->
        case List.keyfind(module.__info__(:attributes), :preferred_cli_env, 0) do
          {:preferred_cli_env, [setting]} ->
            IO.warn(
              """
              setting @preferred_cli_env is deprecated inside Mix tasks.
              Please remove it from #{inspect(module)} and set your preferred environment in mix.exs instead:

                  def cli do
                    [
                      preferred_envs: [docs: "docs"]
                    ]
                  end
              """,
              []
            )

            setting

          _ ->
            nil
        end
    end
  end

  defp reload_project() do
    if project = Mix.Project.pop() do
      %{name: name, file: file} = project
      Mix.Project.push(name, file)
    end
  end

  defp load_dot_config do
    path = Path.join(Mix.Utils.mix_config(), "config.exs")

    if File.regular?(path) do
      Mix.Tasks.Loadconfig.load_compile(path)
    end
  end

  defp display_version do
    IO.puts(:erlang.system_info(:system_version))
    IO.puts("Mix " <> System.build_info()[:build])
  end

  defp display_usage do
    Mix.shell().info("""

    Usage: mix [task]

    Examples:

        mix             - Invokes the default task (mix run) in a project
        mix new PATH    - Creates a new Elixir project at the given path
        mix help        - Lists all available tasks
        mix help TASK   - Prints documentation for a given task

    The --help and --version options can be given instead of a task for usage and versioning information.
    """)
  end

  # Check for --help or --version in the args
  defp check_for_shortcuts([arg]) when arg in ["--help", "-h"], do: :help

  defp check_for_shortcuts([arg]) when arg in ["--version", "-v"], do: :version

  defp check_for_shortcuts(_), do: nil
end
