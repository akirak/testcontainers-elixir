defmodule Testcontainers.Docker.ApiTest do
  use ExUnit.Case, async: true

  alias Testcontainers.Container
  alias Testcontainers.Docker.Api

  describe "build_container_create_request/1" do
    test "includes log config when log driver is set" do
      request =
        "redis:7"
        |> Container.new()
        |> Container.with_log_driver("k8s-file")
        |> Api.build_container_create_request()

      assert request."HostConfig"."LogConfig"."Type" == "k8s-file"
      assert request."HostConfig"."LogConfig"."Config" == %{}
    end

    test "includes log driver options" do
      request =
        "redis:7"
        |> Container.new()
        |> Container.with_log_driver("json-file", %{"max-size" => "10m"})
        |> Api.build_container_create_request()

      assert request."HostConfig"."LogConfig"."Type" == "json-file"
      assert request."HostConfig"."LogConfig"."Config" == %{"max-size" => "10m"}
    end

    test "omits log config by default" do
      request =
        "redis:7"
        |> Container.new()
        |> Api.build_container_create_request()

      assert request."HostConfig"."LogConfig" == nil
    end
  end
end
