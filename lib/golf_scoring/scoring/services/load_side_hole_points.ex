defmodule GolfScoring.Scoring.Services.LoadSideHolePoints do
  @moduledoc """
  Internal, read-only projection of current individual Side-hole points.

  The service owns a repeatable-read transaction so applicability and score
  inputs are observed at the same database snapshot. It does not establish
  scoring eligibility or SideResult readiness.
  """

  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Calculators.{SideHoleContributors, StablefordPoints, StrokeAllocation}
  alias GolfScoring.Scoring.Services.LoadContributionApplicability

  @doc "Returns the 18 scheduled Side holes in the group's playing order."
  def run(event_id, round_id, side_id) do
    with {:ok, event} <- Ecto.UUID.dump(event_id),
         {:ok, round} <- Ecto.UUID.dump(round_id),
         {:ok, side} <- Ecto.UUID.dump(side_id),
         false <- Repo.in_transaction?() do
      execute({event_id, round_id, side_id}, {event, round, side})
    else
      :error -> {:error, :invalid_scope}
      true -> {:error, :outer_transaction_required}
    end
  end

  @doc """
  Projects within an existing caller-owned repeatable-read, read-only transaction.

  The caller owns the transaction and its lifetime. Unsafe contexts are rejected
  before scoring evidence is read.
  """
  def run_in_snapshot(event_id, round_id, side_id) do
    with true <- Repo.in_transaction?(),
         [["repeatable read", "on"]] <-
           Repo.query!(
             "SELECT current_setting('transaction_isolation'), current_setting('transaction_read_only')"
           ).rows,
         {:ok, event} <- Ecto.UUID.dump(event_id),
         {:ok, round} <- Ecto.UUID.dump(round_id),
         {:ok, side} <- Ecto.UUID.dump(side_id) do
      project_snapshot({event_id, round_id, side_id}, {event, round, side})
    else
      :error -> {:error, :invalid_scope}
      _ -> {:error, :invalid_snapshot}
    end
  end

  defp execute(ids, dumped) do
    case Repo.transaction(fn -> read_snapshot(ids, dumped) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_snapshot({event_id, round_id, side_id}, {event, round, side}) do
    Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")

    project_snapshot({event_id, round_id, side_id}, {event, round, side})
  end

  defp project_snapshot({event_id, round_id, side_id}, {event, round, side}) do
    with {:ok, facts} <- LoadContributionApplicability.run_scheduled(event_id, round_id, side_id),
         {:ok, groups} <- SideHoleContributors.select(facts),
         {:ok, inputs} <- load_inputs(event, round, side),
         {:ok, players} <- build_players(inputs, facts) do
      project(groups, players)
    end
  end

  defp load_inputs(event, round, side) do
    rows =
      Repo.query!(
        """
        SELECT e.id::text, rh.id::text, tee.id::text, tee.round_id::text,
               hs.id::text, hs.round_id::text, hs.round_entry_id::text,
               hs.round_tee_profile_snapshot_id::text,
               ch.id::text, ch.round_id::text, ch.round_entry_id::text,
               ch.round_competition_id::text, ch.playing_handicap,
               th.id::text, th.round_id::text, th.round_hole_id::text,
               th.par, th.stroke_index, th.plus_stroke_order,
               sc.id::text, sc.round_id::text, sc.round_entry_id::text,
               hr.id::text, hr.round_id::text, hr.round_hole_id::text,
               hr.scorecard_id::text, hr.revision, hr.outcome, hr.gross_strokes,
               s.round_competition_id::text, r.id::text
        FROM competition_sides s
        JOIN rounds r ON r.id = s.round_id AND r.event_id = $1::uuid
        JOIN round_competitions rc ON rc.id = s.round_competition_id
          AND rc.round_id = r.id AND rc.event_id = r.event_id
        JOIN competition_side_memberships m ON m.competition_side_id = s.id
        JOIN round_entries e ON e.id = m.round_entry_id
        JOIN round_holes rh ON rh.round_id = r.id
        LEFT JOIN round_tee_profile_snapshots tee ON tee.id = e.round_tee_profile_snapshot_id
        LEFT JOIN competition_handicaps ch ON ch.round_entry_id = e.id
          AND ch.round_competition_id = s.round_competition_id
        LEFT JOIN handicap_snapshots hs ON hs.id = ch.handicap_snapshot_id
        LEFT JOIN round_tee_hole_snapshots th ON th.round_tee_profile_snapshot_id = tee.id
          AND th.round_hole_id = rh.id
        LEFT JOIN scorecards sc ON sc.round_entry_id = e.id
        LEFT JOIN hole_results hr ON hr.scorecard_id = sc.id AND hr.round_hole_id = rh.id
        WHERE s.id = $3::uuid AND r.id = $2::uuid
          AND m.round_id = r.id AND m.round_competition_id = s.round_competition_id
          AND e.round_id = r.id AND e.event_id = r.event_id
        ORDER BY e.id, rh.play_order
        """,
        [event, round, side]
      ).rows

    if rows == [], do: {:error, :invalid_scope}, else: {:ok, rows}
  end

  defp build_players(rows, facts) do
    by_entry = Enum.group_by(rows, &hd/1)
    expected = facts |> Enum.map(& &1.round_entry_id) |> MapSet.new()

    if MapSet.new(Map.keys(by_entry)) != expected do
      {:error, :inconsistent_evidence}
    else
      Enum.reduce_while(by_entry, {:ok, %{}}, &collect_player/2)
    end
  end

  defp collect_player({entry, rows}, {:ok, players}) do
    case build_player(entry, rows) do
      {:ok, player} -> {:cont, {:ok, Map.put(players, entry, player)}}
      error -> {:halt, error}
    end
  end

  defp build_player(entry, rows) do
    decoded = Enum.map(rows, &decode/1)
    holes = Enum.map(decoded, & &1.hole)
    first = hd(decoded)

    with true <- length(rows) == 18,
         true <- Enum.all?(decoded, &valid_row?(&1, first, entry)),
         {:ok, %{strokes_by_round_hole_id: strokes}} <-
           StrokeAllocation.allocate(first.handicap, holes) do
      {:ok, %{holes: Map.new(decoded, &{&1.hole.round_hole_id, &1}), strokes: strokes}}
    else
      _ -> {:error, :inconsistent_evidence}
    end
  end

  defp decode([
         entry,
         hole,
         tee,
         tee_round,
         hs,
         hs_round,
         hs_entry,
         hs_tee,
         handicap_id,
         handicap_round,
         handicap_entry,
         handicap_competition,
         handicap,
         tee_hole,
         tee_hole_round,
         tee_hole_hole,
         par,
         index,
         plus,
         card,
         card_round,
         card_entry,
         result,
         result_round,
         result_hole,
         result_card,
         revision,
         outcome,
         gross,
         competition,
         round
       ]) do
    %{
      entry: entry,
      round: round,
      tee: tee,
      tee_round: tee_round,
      hs: hs,
      hs_round: hs_round,
      hs_entry: hs_entry,
      hs_tee: hs_tee,
      handicap_id: handicap_id,
      handicap_round: handicap_round,
      handicap_entry: handicap_entry,
      handicap_competition: handicap_competition,
      handicap: handicap,
      tee_hole: tee_hole,
      tee_hole_round: tee_hole_round,
      tee_hole_hole: tee_hole_hole,
      card: card,
      card_round: card_round,
      card_entry: card_entry,
      result: result,
      result_round: result_round,
      result_hole: result_hole,
      result_card: result_card,
      revision: revision,
      outcome: outcome,
      gross: gross,
      competition: competition,
      hole: %{round_hole_id: hole, par: par, stroke_index: index, plus_stroke_order: plus}
    }
  end

  defp valid_row?(row, first, entry) do
    round = first.round

    same = [
      :round,
      :tee,
      :tee_round,
      :hs,
      :hs_round,
      :hs_entry,
      :hs_tee,
      :handicap_id,
      :handicap_round,
      :handicap_entry,
      :handicap_competition,
      :handicap,
      :card,
      :card_round,
      :card_entry,
      :competition
    ]

    Enum.all?(same, &(Map.fetch!(row, &1) == Map.fetch!(first, &1))) and
      valid_bindings?(row, round, entry) and valid_card?(row, round, entry)
  end

  defp valid_bindings?(row, round, entry) do
    Enum.all?([
      Enum.all?([row.tee, row.hs, row.handicap_id, row.tee_hole], &is_binary/1),
      is_integer(row.handicap),
      is_integer(row.hole.par),
      row.hole.par > 0,
      row.tee_round == round,
      row.hs_round == round,
      row.handicap_round == round,
      row.tee_hole_round == round,
      row.hs_entry == entry,
      row.handicap_entry == entry,
      row.hs_tee == row.tee,
      row.handicap_competition == row.competition,
      row.tee_hole_hole == row.hole.round_hole_id
    ])
  end

  defp valid_card?(%{card: nil, result: nil}, _round, _entry), do: true

  defp valid_card?(row, round, entry) do
    row.card_round == round and row.card_entry == entry and valid_card_result?(row, round)
  end

  defp valid_card_result?(%{result: nil}, _round), do: true

  defp valid_card_result?(row, round) do
    row.result_round == round and row.result_card == row.card and
      row.result_hole == row.hole.round_hole_id and valid_result?(row)
  end

  defp valid_result?(%{revision: revision, outcome: "holed_out", gross: gross}),
    do: is_integer(revision) and revision > 0 and is_integer(gross) and gross > 0

  defp valid_result?(%{revision: revision, outcome: "picked_up", gross: nil}),
    do: is_integer(revision) and revision > 0

  defp valid_result?(_), do: false

  defp project(groups, players) do
    Enum.reduce_while(groups, {:ok, []}, fn group, {:ok, acc} ->
      case project_group(group, players) do
        {:ok, hole} -> {:cont, {:ok, [hole | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, holes} -> {:ok, Enum.reverse(holes)}
      error -> error
    end
  end

  defp project_group(group, players) do
    facts = group.recorded ++ group.missing ++ group.excluded

    with {:ok, members} <- Enum.reduce_while(facts, {:ok, []}, &collect_fact(&1, &2, players)) do
      {:ok,
       %{
         play_index: group.play_index,
         round_hole_id: group.round_hole_id,
         members: Enum.sort_by(members, & &1.round_entry_id)
       }}
    end
  end

  defp collect_fact(fact, {:ok, members}, players) do
    case project_fact(fact, Map.fetch!(players, fact.round_entry_id)) do
      {:ok, member} -> {:cont, {:ok, [member | members]}}
      error -> {:halt, error}
    end
  end

  defp project_fact(fact, player) do
    row = Map.fetch!(player.holes, fact.round_hole_id)

    if row.result == fact.hole_result_id and row.revision == fact.revision do
      with {:ok, status, points} <- points(fact, row, player) do
        {:ok, fact |> Map.put(:status, status) |> Map.put(:points, points)}
      end
    else
      {:error, :inconsistent_evidence}
    end
  end

  defp points(%{withdrawal_applicability: :not_applicable}, _row, _player),
    do: {:ok, :excluded, nil}

  defp points(%{hole_result_id: nil}, _row, _player), do: {:ok, :pending, nil}

  defp points(fact, row, player) do
    outcome =
      case row.outcome do
        "holed_out" -> :holed_out
        "picked_up" -> :picked_up
        _ -> :invalid
      end

    case StablefordPoints.calculate(%{
           outcome: outcome,
           gross_strokes: row.gross,
           par: row.hole.par,
           allocated_strokes: Map.fetch!(player.strokes, fact.round_hole_id)
         }) do
      {:ok, %{competition_points: points}} -> {:ok, :recorded, points}
      _ -> {:error, :inconsistent_evidence}
    end
  end
end
