defmodule Testcontainers.Compose.Cli do
  @moduledoc """
  Subprocess wrapper for Docker Compose CLI interaction.
  """

  require Logger

  alias Testcontainers.DockerCompose

  @doc """
  Runs `docker compose up -d --wait` with the given compose configuration.
  """
  def up(%DockerCompose{} = compose) do
    args = build_up_args(compose)

    case execute(compose, args) do
      {_output, 0} -> :ok
      {output, exit_code} -> handle_up_error(compose, output, exit_code)
    end
  end

  @doc """
  Runs `docker compose down` with the given compose configuration.
  """
  def down(%DockerCompose{} = compose) do
    args = build_down_args(compose)

    case execute(compose, args) do
      {_output, 0} -> :ok
      {output, exit_code} -> {:error, {:compose_down_failed, exit_code, output}}
    end
  end

  @doc """
  Runs `docker compose ps --format=json` and parses the output into a list of maps.
  """
  def ps(%DockerCompose{} = compose) do
    args = build_ps_args(compose)

    case execute(compose, args) do
      {output, 0} -> {:ok, parse_ps_output(output)}
      {output, exit_code} -> {:error, {:compose_ps_failed, exit_code, output}}
    end
  end

  @doc """
  Runs `docker compose pull` with the given compose configuration.
  """
  def pull(%DockerCompose{} = compose) do
    args = build_pull_args(compose)

    case execute(compose, args) do
      {_output, 0} -> :ok
      {output, exit_code} -> {:error, {:compose_pull_failed, exit_code, output}}
    end
  end

  @doc """
  Runs `docker compose logs <service>` and returns the output.
  """
  def logs(%DockerCompose{} = compose, service_name) when is_binary(service_name) do
    args = build_logs_args(compose, service_name)

    case execute(compose, args) do
      {output, 0} -> {:ok, output}
      {output, exit_code} -> {:error, {:compose_logs_failed, exit_code, output}}
    end
  end

  # Command building functions - public for testability

  @doc """
  Builds the argument list for `docker compose up`.
  """
  def build_up_args(%DockerCompose{} = compose, wait \\ true) when is_boolean(wait) do
    wait_args = if wait, do: ["--wait"], else: []

    base_args(compose) ++ ["up", "-d"] ++ wait_args ++ build_args(compose) ++ compose.services
  end

  @doc """
  Builds the argument list for `docker compose down`.
  """
  def build_down_args(%DockerCompose{} = compose) do
    args = base_args(compose) ++ ["down"]

    if compose.remove_volumes do
      args ++ ["-v"]
    else
      args
    end
  end

  @doc """
  Builds the argument list for `docker compose ps`.
  """
  def build_ps_args(%DockerCompose{} = compose) do
    base_args(compose) ++ ["ps", "--format=json"]
  end

  @doc """
  Builds the argument list for `docker compose pull`.
  """
  def build_pull_args(%DockerCompose{} = compose) do
    base_args(compose) ++ ["pull"]
  end

  @doc """
  Builds the argument list for `docker compose logs`.
  """
  def build_logs_args(%DockerCompose{} = compose, service_name) do
    base_args(compose) ++ ["logs", service_name]
  end

  @doc """
  Parses the JSON output from `docker compose ps`.

  Each line is a separate JSON object with fields like Service, ID, State, Publishers.
  """
  def parse_ps_output(output) when is_binary(output) do
    output = strip_ansi(output)

    case decode_ps_json(output) do
      {:ok, entries} ->
        entries

      :error ->
        output
        |> String.trim()
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          line
          |> Jason.decode()
          |> normalize_decoded_ps()
        end)
    end
  end

  @doc """
  Parses the Publishers field from a `docker compose ps` JSON entry
  into a list of `{container_port, host_port}` tuples.
  """
  def parse_publishers(nil), do: []
  def parse_publishers([]), do: []

  def parse_publishers(publishers) when is_list(publishers) do
    publishers
    |> Enum.filter(fn pub ->
      published = Map.get(pub, "PublishedPort", 0)
      published != 0
    end)
    |> Enum.map(fn pub ->
      target = Map.get(pub, "TargetPort", 0)
      published = Map.get(pub, "PublishedPort", 0)
      {target, published}
    end)
    |> Enum.uniq()
  end

  # Private functions

  defp decode_ps_json(output) do
    output
    |> trim_before_json()
    |> Jason.decode()
    |> case do
      {:ok, decoded} -> {:ok, normalize_decoded_ps({:ok, decoded})}
      {:error, _} -> :error
    end
  end

  defp normalize_decoded_ps({:ok, %{} = parsed}), do: [normalize_ps_entry(parsed)]

  defp normalize_decoded_ps({:ok, list}) when is_list(list) do
    Enum.flat_map(list, fn
      %{} = entry -> [normalize_ps_entry(entry)]
      _ -> []
    end)
  end

  defp normalize_decoded_ps(_), do: []

  defp normalize_ps_entry(%{} = entry) do
    entry
    |> Map.put_new("ID", Map.get(entry, "Id", ""))
    |> Map.put_new("Service", service_name(entry))
    |> Map.put_new("Publishers", publishers(entry))
  end

  defp service_name(entry) do
    labels = Map.get(entry, "Labels", %{})

    Map.get(labels, "com.docker.compose.service") ||
      Map.get(labels, "io.podman.compose.service") ||
      ""
  end

  defp publishers(entry) do
    entry
    |> Map.get("Ports", [])
    |> Enum.map(fn port ->
      %{
        "TargetPort" => Map.get(port, "container_port", 0),
        "PublishedPort" => Map.get(port, "host_port", 0),
        "Protocol" => Map.get(port, "protocol", "tcp")
      }
    end)
  end

  defp strip_ansi(output) do
    Regex.replace(~r/\e\[[0-9;]*[[:alpha:]]/, output, "")
  end

  defp trim_before_json(output) do
    case json_start(output) do
      nil -> output
      index -> binary_part(output, index, byte_size(output) - index)
    end
  end

  defp json_start(output) do
    ["{", "["]
    |> Enum.flat_map(fn token ->
      case :binary.match(output, token) do
        {index, 1} -> [index]
        :nomatch -> []
      end
    end)
    |> Enum.min(fn -> nil end)
  end

  defp base_args(%DockerCompose{} = compose) do
    args = ["compose"]

    args =
      if compose.project_name do
        args ++ ["-p", compose.project_name]
      else
        args
      end

    args =
      Enum.reduce(compose.compose_files, args, fn file, acc ->
        acc ++ ["-f", file]
      end)

    Enum.reduce(compose.profiles, args, fn profile, acc ->
      acc ++ ["--profile", profile]
    end)
  end

  defp build_args(%DockerCompose{} = compose) do
    args = []

    args =
      if compose.build do
        args ++ ["--build"]
      else
        args
      end

    case compose.pull do
      :always -> args ++ ["--pull", "always"]
      :never -> args ++ ["--pull", "never"]
      :missing -> args
    end
  end

  defp up_without_wait(%DockerCompose{} = compose) do
    args = build_up_args(compose, false)

    case execute(compose, args) do
      {_output, 0} -> :ok
      {output, exit_code} -> {:error, {:compose_up_failed, exit_code, output}}
    end
  end

  defp handle_up_error(%DockerCompose{} = compose, output, exit_code) do
    if is_unsupported_wait_option?(output) do
      up_without_wait(compose)
    else
      {:error, {:compose_up_failed, exit_code, output}}
    end
  end

  defp is_unsupported_wait_option?(output) when is_binary(output) do
    String.contains?(output, "unrecognized arguments: --wait") or
      String.contains?(output, "unknown flag: --wait")
  end

  defp execute(%DockerCompose{} = compose, args) do
    dir = resolve_directory(compose.filepath)
    env_vars = Enum.map(compose.env, fn {k, v} -> {to_string(k), to_string(v)} end)

    Logger.debug("Running: docker #{Enum.join(args, " ")} in #{dir}")

    System.cmd("docker", args, cd: dir, env: env_vars, stderr_to_stdout: true)
  end

  defp resolve_directory(filepath) do
    if File.dir?(filepath) do
      filepath
    else
      Path.dirname(filepath)
    end
  end
end
