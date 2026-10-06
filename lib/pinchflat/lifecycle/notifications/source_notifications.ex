defmodule Pinchflat.Lifecycle.Notifications.SourceNotifications do
  @moduledoc """
  Contains utilities for sending notifications about sources
  """

  require Logger

  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo
  alias Pinchflat.Settings

  @doc """
  Wraps a function that may change the number of pending  or downloaded
  media items for a source, sending an apprise notification if
  the count changes.

  Returns the return value of the provided function
  """
  def wrap_new_media_notification(servers, source, func) do
    before_count = relevant_media_item_count(source)
    retval = func.()
    after_count = relevant_media_item_count(source)

    send_new_media_notification(servers, source, after_count - before_count)

    retval
  end

  @doc """
  Sends a notification if the count of new media items has changed

  Returns :ok
  """
  def send_new_media_notification(_, _, count) when count <= 0, do: :ok

  def send_new_media_notification(servers, source, changed_count) do
    opts = [
      title: "[Pinchflat] New media found",
      body: notification_body(source, changed_count)
    ]

    case backend_runner().run(with_click_url(servers, source), opts) do
      {:ok, _} ->
        Logger.info("Sent new media notification for source #{source.id}")

      {:error, :no_servers} ->
        Logger.info("No notification servers provided for source #{source.id}")

      {:error, err} ->
        Logger.error("Failed to send new media notification for source #{source.id}: #{err}")
    end

    :ok
  end

  defp relevant_media_item_count(source) do
    if source.download_media do
      pending_media_item_count(source) + downloaded_media_item_count(source)
    else
      0
    end
  end

  defp pending_media_item_count(source) do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.pending()))
    |> Repo.aggregate(:count)
  end

  defp downloaded_media_item_count(source) do
    MediaQuery.new()
    |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.downloaded()))
    |> Repo.aggregate(:count)
  end

  defp backend_runner do
    # This approach lets us mock the command for testing
    Application.get_env(:pinchflat, :apprise_runner)
  end

  defp notification_body(source, changed_count) do
    "Found #{changed_count} new media item(s) for #{source.custom_name}. Downloading them now"
  end

  # Apprise has no `--href`/`--format` CLI flags (never has, across 1.x and 2.x) — a
  # notification's click-through link is set via a `click=` query param on each
  # service URL instead. See https://github.com/caronc/apprise/wiki/URLBasics
  defp with_click_url(servers, _source) when servers in [nil, "", []], do: servers

  defp with_click_url(servers, source) do
    case Settings.get(:external_base_url) do
      {:ok, base_url} when is_binary(base_url) and base_url != "" ->
        click_url = source_url(base_url, source)

        servers
        |> List.wrap()
        |> Enum.map(&append_click_param(&1, click_url))

      _ ->
        servers
    end
  end

  defp append_click_param(server, click_url) do
    separator = if String.contains?(server, "?"), do: "&", else: "?"

    "#{server}#{separator}click=#{URI.encode_www_form(click_url)}"
  end

  defp source_url(base_url, source) do
    "#{String.trim_trailing(base_url, "/")}/sources/#{source.id}"
  end
end
