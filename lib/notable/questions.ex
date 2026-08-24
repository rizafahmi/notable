defmodule Notable.Questions do
  @moduledoc """
  The audience questions context.

  A single permanent board of audience questions with anonymous upvotes,
  status lifecycle (open/answered), and orthogonal hide/restore moderation.
  """

  import Ecto.Query, warn: false

  alias Notable.Questions.Question
  alias Notable.Questions.QuestionVote
  alias Notable.Repo
  alias Notable.Wib

  @pubsub Notable.PubSub
  @topic "questions"

  ## Date helpers (fixed WIB offset — see `Notable.Wib`)

  @doc "The Asia/Jakarta date for a UTC `DateTime`."
  defdelegate wib_date_of_utc_datetime(datetime), to: Wib

  @doc "Today's Asia/Jakarta date for a UTC `DateTime` (defaults to now)."
  def today_wib(now \\ DateTime.utc_now()), do: Wib.today_wib(now)

  @doc """
  Half-open UTC `{start, end}` range covering a single WIB day:
  records with `inserted_at >= start and inserted_at < end` belong to that day.
  """
  defdelegate wib_date_range(date), to: Wib

  ## Public creation

  def create_question(attrs) when is_map(attrs) do
    %Question{}
    |> Question.create_changeset(attrs)
    |> Repo.insert()
    |> broadcast_on_ok(:question_created)
  end

  def create_question!(attrs) when is_map(attrs) do
    case create_question(attrs) do
      {:ok, question} -> question
      {:error, changeset} -> raise "create_question! failed: #{inspect(changeset.errors)}"
    end
  end

  def get_question(id) when is_binary(id) and byte_size(id) > 0, do: Repo.get(Question, id)
  def get_question(_id), do: nil

  ## Vote toggle

  @doc """
  Toggle a visitor's vote on a question, transactionally.

  `visitor_id` is the opaque signed-session value; only its SHA-256 hex hash
  is persisted. Voting is refused when the question is answered, hidden, or
  missing. The unique index is the final concurrency guard, so a racing
  concurrent insert surfaces as `{:error, :already_voted}`.
  """
  def toggle_vote(question_id, visitor_id)
      when is_binary(question_id) and is_binary(visitor_id) do
    visitor_hash = hash_visitor_id(visitor_id)

    Repo.transaction(fn ->
      case Repo.get(Question, question_id) do
        nil ->
          Repo.rollback(:not_found)

        %Question{hidden_at: hidden_at} when not is_nil(hidden_at) ->
          Repo.rollback(:hidden)

        %Question{status: "answered"} ->
          Repo.rollback(:answered)

        %Question{} ->
          toggle_vote_in_transaction(question_id, visitor_hash)
      end
    end)
    |> broadcast_on_ok(:question_changed, question_id)
  end

  defp toggle_vote_in_transaction(question_id, visitor_hash) do
    case Repo.get_by(QuestionVote, question_id: question_id, visitor_hash: visitor_hash) do
      nil ->
        %QuestionVote{}
        |> QuestionVote.changeset(%{question_id: question_id, visitor_hash: visitor_hash})
        |> Repo.insert()
        |> case do
          {:ok, _vote} -> :added
          {:error, _changeset} -> Repo.rollback(:already_voted)
        end

      %QuestionVote{} = vote ->
        {:ok, _} = Repo.delete(vote)
        :removed
    end
  end

  ## Status and moderation

  def mark_answered(id) when is_binary(id) do
    update_status(id, "answered")
  end

  def reopen(id) when is_binary(id) do
    update_status(id, "open")
  end

  defp update_status(id, status) do
    case Repo.get(Question, id) do
      nil -> {:error, :not_found}
      question -> question |> Question.status_changeset(%{status: status}) |> Repo.update()
    end
    |> broadcast_on_ok(:question_changed, id)
  end

  def hide(id) when is_binary(id) do
    case Repo.get(Question, id) do
      nil -> {:error, :not_found}
      question -> question |> Question.hide_changeset() |> Repo.update()
    end
    |> broadcast_on_ok(:question_changed, id)
  end

  def restore(id) when is_binary(id) do
    case Repo.get(Question, id) do
      nil -> {:error, :not_found}
      question -> question |> Question.restore_changeset() |> Repo.update()
    end
    |> broadcast_on_ok(:question_changed, id)
  end

  ## Queries

  @doc """
  Date summaries for the permanent board, newest WIB date first.
  Hidden questions are excluded by default; pass `include_hidden: true` for the
  admin view. Each summary has `wib_date`, `total`, `open`.
  """
  def list_date_summaries(opts \\ []) do
    include_hidden? = Keyword.get(opts, :include_hidden, false)

    Question
    |> maybe_exclude_hidden(include_hidden?)
    |> group_by([q], fragment("date(?, '+7 hours')", q.inserted_at))
    |> select([q], %{
      wib_date: fragment("date(?, '+7 hours')", q.inserted_at),
      total: count(q.id),
      open: fragment("count(case when ? = 'open' then 1 end)", q.status)
    })
    |> order_by([q], desc: fragment("date(?, '+7 hours')", q.inserted_at))
    |> Repo.all()
    |> Enum.map(fn %{wib_date: date, total: total, open: open} ->
      %{wib_date: parse_date!(date), total: total, open: open}
    end)
  end

  @doc """
  Ranked questions for a single WIB date with aggregated vote counts.

  Ordering: open before answered, votes descending, oldest `inserted_at` first,
  then `id` ascending as a stable tie-breaker.

  Options:
  * `:visitor_hash` — marks `voted` true for questions this visitor already voted on.
  * `:include_hidden` — when true (admin), include hidden questions.
  """
  def list_questions_for_date(wib_date, opts \\ []) when is_struct(wib_date, Date) do
    {start_utc, end_utc} = wib_date_range(wib_date)
    visitor_hash = Keyword.get(opts, :visitor_hash)
    include_hidden? = Keyword.get(opts, :include_hidden, false)

    Question
    |> maybe_exclude_hidden(include_hidden?)
    |> where([q], q.inserted_at >= ^start_utc and q.inserted_at < ^end_utc)
    |> join(:left, [q], v in assoc(q, :votes), as: :votes)
    |> group_by([q], q.id)
    |> select([q, v], %{
      question: q,
      vote_count: count(v.id),
      voted: max(fragment("case when ? = ? then 1 else 0 end", v.visitor_hash, ^visitor_hash))
    })
    |> order_by(
      [q, v],
      asc: fragment("case when ? = 'answered' then 1 else 0 end", q.status),
      desc: count(v.id),
      asc: q.inserted_at,
      asc: q.id
    )
    |> Repo.all()
    |> Enum.map(fn row -> %{row | voted: row.voted == 1} end)
  end

  defp maybe_exclude_hidden(query, true), do: query
  defp maybe_exclude_hidden(query, _), do: where(query, [q], is_nil(q.hidden_at))

  ## Broadcasts

  def hash_visitor_id(visitor_id) do
    :crypto.hash(:sha256, visitor_id) |> Base.encode16(case: :lower)
  end

  defp broadcast_on_ok({:ok, %Question{id: id}} = result, event) do
    broadcast({event, id})
    result
  end

  defp broadcast_on_ok(error, _event), do: error

  defp broadcast_on_ok({:ok, _} = result, event, id) do
    broadcast({event, id})
    result
  end

  defp broadcast_on_ok(error, _event, _id), do: error

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, message)
  end

  defp parse_date!(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, d} -> d
      {:error, _} -> raise "invalid WIB date from database: #{inspect(date)}"
    end
  end
end
