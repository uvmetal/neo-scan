defmodule NeoscanSync.Syncer do
  alias Ecto.ConstraintError

  alias NeoscanSync.Converter
  alias Neoscan.Repo
  alias Neoscan.Blocks
  alias Neoscan.Vout
  alias Neoscan.Vin
  alias Neoscan.Claim
  alias Neoscan.Transfer
  alias Neoscan.Transaction
  alias Neoscan.Asset
  use GenServer

  require Logger

  @parallelism 16
  @update_interval 1_000
  @block_chunk_size 5_000

  def start_link do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    missing_block_indexes = Blocks.get_missing_block_indexes()
    Logger.warn("found #{Enum.count(missing_block_indexes)} missing blocks")
    Process.send_after(self(), :sync, 0)
    {:ok, missing_block_indexes}
  end

  defp get_available_block_index_range do
    max_index_in_db = Blocks.get_max_index() + 1
    max_index_available = NeoscanNode.get_last_block_index()

    if max_index_in_db > max_index_available do
      []
    else
      Enum.to_list(max_index_in_db..max_index_available)
    end
  end

  @impl true
  def handle_info(:sync, missing_block_indexes) do
    Process.send_after(self(), :sync, @update_interval)
    available_block_index_range = get_available_block_index_range()
    indexes = missing_block_indexes ++ Enum.take(available_block_index_range, @block_chunk_size)
    sync_indexes(indexes)
    {:noreply, []}
  end

  def download_block(index) do
    try do
      block_raw = NeoscanNode.get_block_with_transfers(index)
      ^index = block_raw.index
      Converter.convert_block(block_raw)
    catch
      error ->
        Logger.error("error while downloading block #{inspect({index, error})}")
        download_block(index)

      error, reason ->
        Logger.error("error while downloading block #{inspect({index, error, reason})}")
        download_block(index)
    end
  end

  def explode_block(block) do
    map = %{
      block: %{block | transactions: []},
      transactions: [],
      vouts: [],
      vins: [],
      claims: [],
      transfers: [],
      assets: []
    }

    Enum.reduce(block.transactions, map, fn transaction, acc ->
      %{
        acc
        | transactions: [
            Map.drop(transaction, [:vouts, :vins, :claims, :transfers, :asset]) | acc.transactions
          ],
          vouts: transaction.vouts ++ acc.vouts,
          vins: transaction.vins ++ acc.vins,
          claims: transaction.claims ++ acc.claims,
          transfers: transaction.transfers ++ acc.transfers,
          assets: if(is_nil(transaction.asset), do: [], else: [transaction.asset]) ++ acc.assets
      }
    end)
  end

  defp insert_all(schema, data) do
    data
    |> Enum.chunk_every(1_000)
    |> Enum.map(&Repo.insert_all(schema, &1, timeout: :infinity))
  end

  def insert_block(block) do
    exploded_block = explode_block(block)

    try do
      Repo.transaction(
        fn ->
          Repo.insert!(exploded_block.block, timeout: :infinity)
          insert_all(Transaction, exploded_block.transactions)
          insert_all(Vin, exploded_block.vins)
          insert_all(Vout, exploded_block.vouts)
          insert_all(Claim, exploded_block.claims)
          insert_all(Transfer, exploded_block.transfers)
          insert_all(Asset, exploded_block.assets)
        end,
        timeout: :infinity
      )

      :ok
    catch
      error ->
        Logger.error("error while loading block #{inspect({block.index, error})}")
        insert_block(block)

      :error, %ConstraintError{constraint: "blocks_pkey"} ->
        Logger.error("block already #{block.index} in the database")

      error, reason ->
        Logger.error("error while loading block #{inspect({block.index, error, reason})}")
        insert_block(block)
    end
  end

  def sync_indexes(indexes) do
    concurrency = System.schedulers_online() * @parallelism

    indexes
    |> Task.async_stream(
      fn n ->
        now = Time.utc_now()
        block = download_block(n)
        Monitor.incr(:download_blocks_time, Time.diff(Time.utc_now(), now, :microseconds))
        Monitor.incr(:download_blocks_count, 1)
        block
      end,
      max_concurrency: concurrency,
      timeout: :infinity,
      ordered: false
    )
    |> Task.async_stream(
      fn {:ok, block} ->
        now = Time.utc_now()
        insert_block(block)
        Monitor.incr(:insert_blocks_time, Time.diff(Time.utc_now(), now, :microseconds))
        Monitor.incr(:insert_blocks_count, 1)
      end,
      max_concurrency: 1,
      timeout: :infinity
    )
    |> Stream.run()
  end
end
