defmodule Testcontainers.HttpWaitStrategy do
  @moduledoc """
  Considers the container as ready when a http request is successful.
  """

  @timeout 60_000
  @max_retries 10

  @typedoc """
  The HttpWaitStrategy struct

  ## Options

  - `:endpoint` - The endpoint to request

  - `:port` - The exposed port of your container

  Verification Options:

  - `:status_code` - Check if the request responds with the given status code

  - `:match` - Run your custom matcher on the given response. A 1-arity function
    taking a response as first parameter and must return a boolean

  Request Options:

  - `:protocol` - which protocol to use, defaults to `http`

  - `:method` - the request method, one of [`:head`, `:get`, `:delete`, `:trace`, `:options`, `:post`, `:put`, `:patch`]

  - `:timeout` - The timeout of the request (in milliseconds), defaults to `5000`

  - `:headers` - Apply any headers to your request
  """
  @type t() :: %__MODULE__{
          endpoint: String.t(),
          port: integer(),
          protocol: String.t(),
          method: :get | :post | :patch | :put | :delete | :head | :options | :trace,
          timeout: integer(),
          headers: [{binary(), binary()}],
          status_code: integer(),
          match: (map() -> boolean())
        }

  defstruct [
    :endpoint,
    :port,
    # request options
    protocol: "http",
    method: :get,
    headers: [],
    timeout: @timeout,
    max_retries: @max_retries,
    # verification options
    status_code: nil,
    match: nil
  ]

  # Public interface

  @doc """
  Creates a new HttpWaitStrategy to wait until a http requests succeeds.
  """
  def new(endpoint, port, options \\ []) do
    struct(%__MODULE__{endpoint: endpoint, port: port}, options)
  end

  # Private functions and implementations

  defimpl Testcontainers.WaitStrategy do
    alias Testcontainers.Container
    alias Testcontainers.HttpWaitStrategy

    @impl true
    def wait_until_container_is_ready(wait_strategy, container, _conn) do
      wait_strategy
      |> build_request(container)
      |> request_until_ready(wait_strategy, started_at())
    end

    # Response evaluation

    defp validate_response({:ok, response}), do: {:ok, response}
    defp validate_response({:error, reason}), do: {:error, reason}

    defp verify_status_code(wait_strategy, %{status: status_code})
         when not is_nil(wait_strategy.status_code) and
                status_code == wait_strategy.status_code,
         do: :ok

    defp verify_status_code(wait_strategy, response) when not is_nil(wait_strategy.status_code),
      do:
        {:error,
         "Status Code does not match. Expected: #{wait_strategy.status_code} Received: #{response.status}"}

    defp verify_status_code(wait_strategy, _) when is_nil(wait_strategy.status_code), do: :ok

    defp verify_match(wait_strategy, response)
         when not is_nil(wait_strategy.match) and is_function(wait_strategy.match) do
      case wait_strategy.match.(response) do
        true -> :ok
        false -> {:error, "Matcher function failed"}
      end
    end

    defp verify_match(_, _), do: :ok

    # Request composition

    defp build_request(wait_strategy, container) do
      base_url = get_base_url(wait_strategy, container)
      request_timeout = request_timeout(wait_strategy)

      Tesla.client([
        {Tesla.Middleware.BaseUrl, base_url: base_url},
        {Tesla.Middleware.Timeout, timeout: request_timeout}
      ])
    end

    defp get_base_url(%HttpWaitStrategy{} = wait_strategy, %Container{} = container) do
      port = Testcontainers.get_port(container, wait_strategy.port)

      "#{wait_strategy.protocol}://#{Testcontainers.get_host(container)}:#{port}/"
    end

    defp request_timeout(%HttpWaitStrategy{timeout: timeout, max_retries: max_retries})
         when max_retries > 0 do
      timeout
      |> div(max_retries)
      |> max(1)
    end

    defp request_until_ready(client, wait_strategy, started_at) do
      case request_and_verify(client, wait_strategy) do
        :ok ->
          :ok

        {:error, reason} ->
          maybe_retry(client, wait_strategy, started_at, reason)
      end
    end

    defp request_and_verify(client, wait_strategy) do
      raw_response =
        Tesla.request(client,
          url: wait_strategy.endpoint,
          method: wait_strategy.method,
          headers: wait_strategy.headers
        )

      with {:ok, response} <- validate_response(raw_response),
           :ok <- verify_status_code(wait_strategy, response) do
        verify_match(wait_strategy, response)
      end
    end

    defp maybe_retry(client, wait_strategy, started_at, reason) do
      if timed_out?(started_at, wait_strategy.timeout) do
        {:error, reason, wait_strategy}
      else
        :timer.sleep(retry_delay(wait_strategy, started_at))
        request_until_ready(client, wait_strategy, started_at)
      end
    end

    defp retry_delay(wait_strategy, started_at) do
      wait_strategy.timeout
      |> remaining_timeout(started_at)
      |> min(500)
      |> max(0)
    end

    defp timed_out?(started_at, timeout), do: elapsed_time(started_at) >= timeout

    defp remaining_timeout(timeout, started_at), do: timeout - elapsed_time(started_at)

    defp elapsed_time(started_at), do: System.monotonic_time(:millisecond) - started_at

    defp started_at, do: System.monotonic_time(:millisecond)
  end
end
