# SPDX-License-Identifier: MIT
defmodule Testcontainers.PlaywrightContainer do
  @moduledoc """
  A container with the Microsoft Playwright image and a ready-to-use Playwright
  Node package installed inside the container.
  """
  alias Testcontainers.CommandWaitStrategy
  alias Testcontainers.Container
  alias Testcontainers.ContainerBuilder
  alias Testcontainers.Docker
  alias Testcontainers.PlaywrightContainer

  import Testcontainers.Container, only: [is_valid_image: 1]

  @default_image "mcr.microsoft.com/playwright"
  @default_tag "v1.52.0-noble"
  @default_package_version "1.52.0"
  @default_image_with_tag "#{@default_image}:#{@default_tag}"
  @default_cmd ["tail", "-f", "/dev/null"]
  @default_wait_timeout 120_000
  @default_install_timeout 300_000
  @workspace "/tmp/testcontainers-playwright"

  @type t :: %__MODULE__{}

  @enforce_keys [:image, :wait_timeout, :install_timeout, :package_version]
  defstruct [
    :image,
    :wait_timeout,
    :install_timeout,
    :package_version,
    check_image: @default_image,
    reuse: false
  ]

  def new,
    do: %__MODULE__{
      image: @default_image_with_tag,
      wait_timeout: @default_wait_timeout,
      install_timeout: @default_install_timeout,
      package_version: @default_package_version
    }

  def with_image(%__MODULE__{} = config, image) when is_binary(image) do
    %{config | image: image}
  end

  def with_wait_timeout(%__MODULE__{} = config, wait_timeout) when is_integer(wait_timeout) do
    %{config | wait_timeout: wait_timeout}
  end

  def with_install_timeout(%__MODULE__{} = config, install_timeout)
      when is_integer(install_timeout) do
    %{config | install_timeout: install_timeout}
  end

  def with_package_version(%__MODULE__{} = config, package_version)
      when is_binary(package_version) do
    %{config | package_version: package_version}
  end

  @doc """
  Set the regular expression to check the image validity.
  """
  def with_check_image(%__MODULE__{} = config, check_image) when is_valid_image(check_image) do
    %__MODULE__{config | check_image: check_image}
  end

  @doc """
  Set the reuse flag to reuse the container if it is already running.
  """
  def with_reuse(%__MODULE__{} = config, reuse) when is_boolean(reuse) do
    %__MODULE__{config | reuse: reuse}
  end

  def default_image, do: @default_image

  def workspace, do: @workspace

  defimpl ContainerBuilder do
    import Container

    @spec build(PlaywrightContainer.t()) :: Container.t()
    @impl true
    def build(%PlaywrightContainer{} = config) do
      new(config.image)
      |> with_cmd(PlaywrightContainer.default_cmd())
      |> with_waiting_strategy(
        CommandWaitStrategy.new(["node", "--version"], config.wait_timeout, 1000)
      )
      |> with_check_image(config.check_image)
      |> with_reuse(config.reuse)
      |> valid_image!()
    end

    @impl true
    def after_start(%PlaywrightContainer{} = config, container, conn) do
      install_command = [
        "bash",
        "-lc",
        "mkdir -p #{PlaywrightContainer.workspace()} && cd #{PlaywrightContainer.workspace()} && " <>
          "npm init -y >/dev/null 2>&1 && " <>
          "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install playwright@#{config.package_version}"
      ]

      with {:ok, exec_id} <- Docker.Api.start_exec(container.container_id, install_command, conn) do
        wait_for_exec(exec_id, conn, config.install_timeout, System.monotonic_time(:millisecond))
      end
    end

    defp wait_for_exec(exec_id, conn, timeout, started_at) do
      if System.monotonic_time(:millisecond) - started_at > timeout do
        {:error, {:exec_timeout, exec_id, timeout}}
      else
        case Docker.Api.inspect_exec(exec_id, conn) do
          {:ok, %{running: true}} ->
            Process.sleep(500)
            wait_for_exec(exec_id, conn, timeout, started_at)

          {:ok, %{running: false, exit_code: 0}} ->
            :ok

          {:ok, %{running: false, exit_code: code}} ->
            {:error, {:exec_failed, code}}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  def default_cmd, do: @default_cmd
end
