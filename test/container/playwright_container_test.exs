# SPDX-License-Identifier: MIT
defmodule Testcontainers.Container.PlaywrightContainerTest do
  use ExUnit.Case, async: true
  import Testcontainers.ExUnit

  alias Testcontainers.Connection
  alias Testcontainers.Docker
  alias Testcontainers.PlaywrightContainer

  container(:playwright, PlaywrightContainer.new(), shared: true)

  describe "with default configuration" do
    test "handles click interactions and DOM assertions", %{playwright: playwright} do
      assert :ok =
               run_playwright(playwright, """
               const { chromium } = require("playwright");

               (async () => {
                 const browser = await chromium.launch({
                   args: ["--no-sandbox", "--disable-dev-shm-usage"]
                 });
                 const page = await browser.newPage();
                 await page.setContent(`
                   <button id="save">Save</button>
                   <output id="status">idle</output>
                   <script>
                     document.querySelector("#save").addEventListener("click", () => {
                       document.querySelector("#status").textContent = "saved";
                     });
                   </script>
                 `);
                 await page.click("#save");
                 const status = await page.textContent("#status");
                 await browser.close();

                 if (status !== "saved") {
                   throw new Error(`expected saved status, got ${status}`);
                 }
               })().catch(error => {
                 console.error(error);
                 process.exit(1);
               });
               """)
    end

    test "fills forms and submits with the keyboard", %{playwright: playwright} do
      assert :ok =
               run_playwright(playwright, """
               const { chromium } = require("playwright");

               (async () => {
                 const browser = await chromium.launch({
                   args: ["--no-sandbox", "--disable-dev-shm-usage"]
                 });
                 const page = await browser.newPage();
                 await page.setContent(`
                   <form id="profile">
                     <label>Name <input id="name" name="name" /></label>
                     <output id="result"></output>
                   </form>
                   <script>
                     document.querySelector("#profile").addEventListener("submit", event => {
                       event.preventDefault();
                       document.querySelector("#result").textContent =
                         "Hello " + new FormData(event.target).get("name");
                     });
                   </script>
                 `);
                 await page.fill("#name", "Ada");
                 await page.press("#name", "Enter");
                 await page.waitForFunction(() =>
                   document.querySelector("#result").textContent === "Hello Ada"
                 );
                 await browser.close();
               })().catch(error => {
                 console.error(error);
                 process.exit(1);
               });
               """)
    end

    test "waits for dynamic UI state changes", %{playwright: playwright} do
      assert :ok =
               run_playwright(playwright, """
               const { chromium } = require("playwright");

               (async () => {
                 const browser = await chromium.launch({
                   args: ["--no-sandbox", "--disable-dev-shm-usage"]
                 });
                 const page = await browser.newPage();
                 await page.setContent(`
                   <button id="load">Load</button>
                   <ul id="items"></ul>
                   <script>
                     document.querySelector("#load").addEventListener("click", () => {
                       setTimeout(() => {
                         document.querySelector("#items").innerHTML =
                           "<li>alpha</li><li>beta</li><li>gamma</li>";
                       }, 100);
                     });
                   </script>
                 `);
                 await page.click("#load");
                 await page.waitForSelector("#items li:nth-child(3)");
                 const items = await page.locator("#items li").allTextContents();
                 await browser.close();

                 if (items.join(",") !== "alpha,beta,gamma") {
                   throw new Error(`unexpected items: ${items.join(",")}`);
                 }
               })().catch(error => {
                 console.error(error);
                 process.exit(1);
               });
               """)
    end
  end

  defp run_playwright(container, script) do
    command = [
      "bash",
      "-lc",
      "cd #{PlaywrightContainer.workspace()} && node -e #{escape(script)}"
    ]

    conn = Connection.get_connection() |> Tuple.to_list() |> hd()

    with {:ok, exec_id} <- Docker.Api.start_exec(container.container_id, command, conn) do
      wait_for_exec(exec_id, conn, System.monotonic_time(:millisecond))
    end
  end

  defp wait_for_exec(exec_id, conn, started_at) do
    if System.monotonic_time(:millisecond) - started_at > 120_000 do
      {:error, {:exec_timeout, exec_id}}
    else
      case Docker.Api.inspect_exec(exec_id, conn) do
        {:ok, %{running: true}} ->
          Process.sleep(250)
          wait_for_exec(exec_id, conn, started_at)

        {:ok, %{running: false, exit_code: 0}} ->
          :ok

        {:ok, %{running: false, exit_code: code}} ->
          {:error, {:exec_failed, code}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp escape(script) do
    script
    |> String.replace("'", "'\"'\"'")
    |> then(&"'#{&1}'")
  end
end
