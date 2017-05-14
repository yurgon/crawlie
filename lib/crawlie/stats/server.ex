defmodule Crawlie.Stats.Server do
  use GenServer

  alias Crawlie.Page
  alias Crawlie.Response
  alias Crawlie.Utils

  alias Crawlie.Stats.Counter, as: Count
  alias Crawlie.Stats.Distribution, as: Dist

  defmodule Data do
    alias __MODULE__, as: This

    defstruct [
      uris_visited: 0, # fetch
      uris_extracted: 0, # extract
      depths_dist: %{}, # fetch
      retry_count_dist: %{}, # fetch
      bytes_received: 0, # fetch
      status_codes_dist: %{}, # fetch
      content_types_dist: %{}, # fetch
      failed_fetch_uris: MapSet.new(), # fetch
      uris_skipped: 0, # parse
      failed_parse_uris: MapSet.new(), # parse

      status: :ready, # | :crawling | :finished # fetch, also UrlManager.shutdown_gracefully()

      utimestamp_started: nil, # see status
      utimestamp_finished: nil, # see status
      usec_spent_fetching: 0, # fetch
    ]

    def new(), do: %This{}
  end

  defmodule ResponseView do
    defstruct [
      :status_code,
      :content_type_simple,
      :body_length,
    ]

    def new(%Response{} = resp) do
      %ResponseView {
        status_code: resp.status_code,
        content_type_simple: Response.content_type_simple(resp),
        body_length: byte_size(resp.body),
      }
    end
  end


  alias __MODULE__, as: This

  @ref_marker :stats

  @type ref :: {:stats, pid()}

  #===========================================================================
  # API Functions
  #===========================================================================

  @spec start_new() :: ref
  @doc false
  def start_new() do
    {:ok, pid} = Crawlie.Supervisor.start_stats_server
    pid_to_ref(pid)
  end


  @spec get_stats(ref) :: map

  def get_stats(ref) do
    pid = ref_to_pid(ref)
    GenServer.call(pid, :get_stats)
  end


  def fetch_succeeded(ref, page, response, duration_usec) do
    pid = ref_to_pid(ref)
    response_view = ResponseView.new(response)
    GenServer.cast(pid, {:fetch_succeeded, page, response_view, duration_usec})
  end


  def fetch_failed(ref, page, max_failed_uris_to_track) do
    pid = ref_to_pid(ref)
    GenServer.cast(pid, {:fetch_failed, page, max_failed_uris_to_track})
  end


  def parse_failed(ref, page, max_failed_uris_to_track) do
    pid = ref_to_pid(ref)
    GenServer.cast(pid, {:parse_failed, page, max_failed_uris_to_track})
  end


  def page_skipped(ref, _page) do
    pid = ref_to_pid(ref)
    GenServer.cast(pid, :page_skipped)
  end


  def uris_extracted(ref, count) do
    pid = ref_to_pid(ref)
    GenServer.cast(pid, {:uris_extracted, count})
  end

  def finished(ref) do
    pid = ref_to_pid(ref)
    GenServer.cast(pid, :finished)
  end

  #===========================================================================
  # Business logic
  #===========================================================================

  def handle_call(:get_stats, _from, state) do
    {:reply, state, state}
  end


  def handle_cast({:fetch_succeeded, %Page{} = page, %ResponseView{} = response_view, duration_usec}, data) do
    # TODO add time spent fetching
    %Page{uri: _uri, retries: retries, depth: depth} = page
    %ResponseView {status_code: status_code, content_type_simple: content_type, body_length: body_length} = response_view

    data =
      data
      |> maybe_start_crawling()
      |> Count.inc(:usec_spent_fetching, duration_usec)

    data = case retries do
      0 ->
        data
          |> Count.inc(:uris_visited)
          |> Dist.add(:depths_dist, depth)
          |> Dist.add(:retry_count_dist, 0)
          |> Count.inc(:bytes_received, body_length)
          |> Dist.add(:status_codes_dist, status_code)
          |> Dist.add(:content_types_dist, content_type)
      ret when ret > 0 ->
        data
          |> Dist.remove(:retry_count_dist, ret - 1)
          |> Dist.add(:retry_count_dist, ret)
    end

    {:noreply, data}
  end

  def handle_cast({:fetch_failed, %Page{} = page, max_uris_to_track}, %Data{failed_fetch_uris: failed_fetch_uris} = data) do
    failed_fetch_uris =
      case MapSet.size(failed_fetch_uris) do
        few when few < max_uris_to_track -> MapSet.put(failed_fetch_uris, page.uri)
        _ -> failed_fetch_uris
      end
    {:noreply, %Data{data | failed_fetch_uris: failed_fetch_uris}}
  end

  def handle_cast({:parse_failed, %Page{} = page, max_uris_to_track}, %Data{failed_parse_uris: failed_parse_uris} = data) do
    failed_parse_uris =
      case MapSet.size(failed_parse_uris) do
        few when few < max_uris_to_track -> MapSet.put(failed_parse_uris, page.uri)
        _ -> failed_parse_uris
      end
    {:noreply, %Data{data | failed_parse_uris: failed_parse_uris}}
  end

  def handle_cast(:page_skipped, data) do
    data = Count.inc(data, :uris_skipped)
    {:noreply, data}
  end

  def handle_cast({:uris_extracted, count}, data) do
    data = Count.inc(data, :uris_extracted, count)
    {:noreply, data}
  end

  def handle_cast(:finished, %Data{status: :finished} = data) do
    {:noreply, data}
  end

  def handle_cast(:finished, %Data{} = data) do
    data = %Data{
      data |
      status: :finished,
      utimestamp_finished: Utils.utimestamp(),
    }
    {:noreply, data}
  end

  #===========================================================================
  # Plumbing
  #===========================================================================

  def init([]) do
    state = This.Data.new()
    {:ok, state}
  end

  def start_link() do
    GenServer.start_link(__MODULE__, [])
  end


  #===========================================================================
  # Inernal Functions
  #===========================================================================

  defp pid_to_ref(pid) do
    {@ref_marker, pid}
  end


  defp ref_to_pid({@ref_marker, pid}), do: pid


  defp maybe_start_crawling(%Data{status: :ready} = data) do
    %Data{data | status: :crawling, utimestamp_started: Utils.utimestamp()}
  end

  defp maybe_start_crawling(%Data{status: _} = data), do: data
end
