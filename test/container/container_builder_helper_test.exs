defmodule Testcontainers.ContainerBuilderHelperTest do
  use ExUnit.Case, async: false

  alias Testcontainers.ContainerBuilderHelper
  import Testcontainers.Constants

  test "build/2 returns a tuple with false, built config with correct labels and nil for hash" do
    builder =
      Testcontainers.PostgresContainer.new() |> Testcontainers.PostgresContainer.with_reuse(true)

    state = %{properties: %{}, session_id: "123"}
    {:noreuse, built, nil} = ContainerBuilderHelper.build(builder, state)
    assert Map.get(built.labels, container_reuse()) == "false"
    assert Map.get(built.labels, container_reuse_hash_label()) == nil
    assert Map.get(built.labels, container_session_id_label()) == "123"
    assert Map.get(built.labels, container_version_label()) == library_version()
    assert Map.get(built.labels, container_lang_label()) == container_lang_value()
    assert Map.get(built.labels, container_label()) == "true"
  end

  test "build/2 returns a tuple with true, built config with correct labels and a non nil hash" do
    builder =
      Testcontainers.PostgresContainer.new() |> Testcontainers.PostgresContainer.with_reuse(true)

    state = %{properties: %{"testcontainers.reuse.enable" => "true"}, session_id: "123"}
    {:reuse, built, hash} = ContainerBuilderHelper.build(builder, state)
    assert hash != nil
    assert Map.get(built.labels, container_reuse()) == "true"
    assert Map.get(built.labels, container_reuse_hash_label()) != nil
    assert Map.get(built.labels, container_session_id_label()) == "123"
    assert Map.get(built.labels, container_version_label()) == library_version()
    assert Map.get(built.labels, container_lang_label()) == container_lang_value()
    assert Map.get(built.labels, container_label()) == "true"
  end

  test "build/2 applies podman log driver from properties" do
    builder = Testcontainers.Container.new("redis:7")

    state = %{properties: %{"podman.log.driver" => "k8s-file"}, session_id: "123"}
    {:noreuse, built, nil} = ContainerBuilderHelper.build(builder, state)

    assert built.log_driver == "k8s-file"
    assert built.log_options == %{}
  end

  test "build/2 does not override a container log driver" do
    builder =
      Testcontainers.Container.new("redis:7")
      |> Testcontainers.Container.with_log_driver("json-file")

    state = %{properties: %{"podman.log.driver" => "k8s-file"}, session_id: "123"}
    {:noreuse, built, nil} = ContainerBuilderHelper.build(builder, state)

    assert built.log_driver == "json-file"
  end
end
