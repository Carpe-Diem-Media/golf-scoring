defmodule GolfScoring.LockProtocol do
  @moduledoc """
  Shared PostgreSQL row-lock protocol for Phase 4B/5 gameplay and scoring paths.

  See `docs/golf_scoring_v2_lock_protocol.md` for the authoritative contract.
  """

  alias GolfScoring.Repo

  @relation_order [
    :round,
    :playing_group,
    :group_role_assignment,
    :competition_side,
    :competition_side_result,
    :score_row,
    :verification_row,
    :query_row,
    :mystery_hole_rule,
    :mystery_reveal
  ]

  @implemented_class_atoms [
    :round,
    :playing_group,
    :group_role_assignment,
    :competition_side,
    :competition_side_result,
    :score_row,
    :mystery_hole_rule
  ]

  @doc false
  @spec relation_order() :: [atom()]
  def relation_order, do: @relation_order

  @doc false
  @spec implemented_lock_classes() :: [atom()]
  def implemented_lock_classes, do: @implemented_class_atoms

  @doc false
  @spec acquire!(keyword()) :: {:ok, map()} | {:error, term()}
  def acquire!(requests) when is_list(requests) do
    unless Repo.in_transaction?() do
      raise ArgumentError, "shared lock protocol requires an open repository transaction"
    end

    with {:ok, request_map} <- build_request_map(requests),
         :ok <- validate_request_map(request_map) do
      acquire_in_order(request_map)
    end
  end

  defp build_request_map(requests) do
    Enum.reduce_while(requests, {:ok, %{}}, fn
      {class, ids}, {:ok, acc} when is_atom(class) and is_list(ids) ->
        new_acc =
          Map.update(acc, class, normalize_ids(ids), fn existing ->
            normalize_ids(existing ++ ids)
          end)

        {:cont, {:ok, new_acc}}

      {class, _}, {:ok, _acc} when is_atom(class) ->
        {:halt, {:error, {:invalid_lock_request, class}}}

      _, {:ok, _acc} ->
        {:halt, {:error, :invalid_lock_request}}
    end)
  end

  defp validate_request_map(request_map) do
    with :ok <- validate_known_classes(request_map) do
      validate_class_availability(request_map)
    end
  end

  defp validate_known_classes(request_map) do
    case unknown_lock_class(request_map) do
      nil -> :ok
      class -> {:error, {:unknown_lock_class, class}}
    end
  end

  defp unknown_lock_class(request_map) do
    Map.keys(request_map)
    |> Enum.find(&(&1 not in @relation_order))
  end

  defp validate_class_availability(request_map) do
    Enum.reduce_while(request_map, :ok, fn {class, ids}, :ok ->
      validate_class_availability(class, ids)
    end)
  end

  defp validate_class_availability(_class, []), do: {:cont, :ok}

  defp validate_class_availability(class, _ids) when class in @relation_order do
    if class in @implemented_class_atoms do
      {:cont, :ok}
    else
      {:halt, {:error, {:lock_class_not_yet_available, class}}}
    end
  end

  defp acquire_in_order(request_map) do
    request_map
    |> requested_classes()
    |> Enum.reduce_while({:ok, %{acquired: []}}, &acquire_class(&1, &2, request_map))
  end

  defp requested_classes(request_map) do
    Enum.filter(@relation_order, fn class ->
      Map.get(request_map, class, []) != []
    end)
  end

  defp acquire_class(class, {:ok, acc}, request_map) do
    ids = Map.fetch!(request_map, class)

    case lock_class(class, ids) do
      {:ok, rows} ->
        acquired = map_acquired_rows(class, rows)
        {:cont, {:ok, %{acquired: acc.acquired ++ acquired}}}

      {:error, _} = error ->
        {:halt, error}
    end
  end

  defp map_acquired_rows(class, rows) do
    Enum.map(rows, fn %{id: id, row: row} ->
      %{class: class, id: id, row: row}
    end)
  end

  defp normalize_ids(ids) do
    ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&Ecto.UUID.dump!/1)
  end

  defp lock_class(:round, ids), do: lock_rows(ids, &lock_round/1)
  defp lock_class(:playing_group, ids), do: lock_rows(ids, &lock_playing_group/1)

  defp lock_class(:group_role_assignment, ids),
    do: lock_rows(ids, &lock_group_role_assignment/1)

  defp lock_class(:competition_side, ids), do: lock_rows(ids, &lock_competition_side/1)

  defp lock_class(:competition_side_result, ids),
    do: lock_rows(ids, &lock_competition_side_result/1)

  defp lock_class(:score_row, ids), do: lock_rows(ids, &lock_scorecard/1)

  defp lock_class(:mystery_hole_rule, ids), do: lock_rows(ids, &lock_mystery_hole_rule/1)

  defp lock_rows(ids, lock_fun) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case lock_fun.(id) do
        {:ok, row} -> {:cont, {:ok, acc ++ [%{id: id, row: row}]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp lock_round(round_id) do
    case Repo.query!(
           "SELECT id::text, event_id::text, state FROM rounds WHERE id = $1::uuid FOR UPDATE",
           [Ecto.UUID.dump!(round_id)]
         ).rows do
      [[id, event_id, state]] ->
        {:ok,
         %{
           id: Ecto.UUID.cast!(id),
           event_id: Ecto.UUID.cast!(event_id),
           state: state
         }}

      [] ->
        {:error, :round_not_found}
    end
  end

  defp lock_playing_group(playing_group_id) do
    case Repo.query!(
           """
           SELECT id::text, round_id::text, state, scoring_revision, starting_round_hole_id::text
           FROM playing_groups
           WHERE id = $1::uuid
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(playing_group_id)]
         ).rows do
      [[id, round_id, state, scoring_revision, starting_round_hole_id]] ->
        {:ok,
         %{
           id: Ecto.UUID.cast!(id),
           round_id: Ecto.UUID.cast!(round_id),
           state: state,
           scoring_revision: scoring_revision,
           starting_round_hole_id: cast_optional_uuid(starting_round_hole_id)
         }}

      [] ->
        {:error, :playing_group_not_found}
    end
  end

  defp cast_optional_uuid(nil), do: nil

  defp cast_optional_uuid(value) do
    {:ok, uuid} = Ecto.UUID.cast(value)
    uuid
  end

  defp lock_group_role_assignment(assignment_id) do
    case Repo.query!(
           """
           SELECT id::text, round_id::text, playing_group_id::text, round_entry_id::text,
                  role, state, assignment_version
           FROM group_role_assignments
           WHERE id = $1::uuid
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(assignment_id)]
         ).rows do
      [[id, round_id, group_id, entry_id, role, state, version]] ->
        {:ok,
         %{
           id: Ecto.UUID.cast!(id),
           round_id: Ecto.UUID.cast!(round_id),
           playing_group_id: Ecto.UUID.cast!(group_id),
           round_entry_id: Ecto.UUID.cast!(entry_id),
           role: role,
           state: state,
           assignment_version: version
         }}

      [] ->
        {:error, :group_role_assignment_not_found}
    end
  end

  defp lock_competition_side(competition_side_id) do
    case Repo.query!(
           """
           SELECT id::text, round_id::text, round_competition_id::text, formation
           FROM competition_sides
           WHERE id = $1::uuid
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(competition_side_id)]
         ).rows do
      [[id, round_id, competition_id, formation]] ->
        {:ok,
         %{
           id: Ecto.UUID.cast!(id),
           round_id: Ecto.UUID.cast!(round_id),
           round_competition_id: Ecto.UUID.cast!(competition_id),
           formation: formation
         }}

      [] ->
        {:error, :competition_side_not_found}
    end
  end

  defp lock_competition_side_result(result_id) do
    case Repo.query!(
           """
           SELECT id::text, competition_side_id::text, state
           FROM competition_side_results
           WHERE id = $1::uuid
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(result_id)]
         ).rows do
      [[id, side_id, state]] ->
        {:ok,
         %{
           id: Ecto.UUID.cast!(id),
           competition_side_id: Ecto.UUID.cast!(side_id),
           state: state
         }}

      [] ->
        {:error, :competition_side_result_not_found}
    end
  end

  defp lock_scorecard(scorecard_id) do
    case Repo.query!(
           """
           SELECT id::text, round_id::text, round_entry_id::text, state
           FROM scorecards
           WHERE id = $1::uuid
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(scorecard_id)]
         ).rows do
      [[id, round_id, round_entry_id, state]] ->
        {:ok,
         %{
           id: Ecto.UUID.cast!(id),
           round_id: Ecto.UUID.cast!(round_id),
           round_entry_id: Ecto.UUID.cast!(round_entry_id),
           state: state
         }}

      [] ->
        {:error, :scorecard_not_found}
    end
  end

  defp lock_mystery_hole_rule(rule_id) do
    case Repo.query!(
           """
           SELECT id::text, scoring_track_id::text, round_hole_id::text, rule
           FROM mystery_hole_rules
           WHERE id = $1::uuid
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(rule_id)]
         ).rows do
      [[id, track_id, round_hole_id, rule]] ->
        {:ok,
         %{
           id: Ecto.UUID.cast!(id),
           scoring_track_id: Ecto.UUID.cast!(track_id),
           round_hole_id: Ecto.UUID.cast!(round_hole_id),
           rule: rule
         }}

      [] ->
        {:error, :mystery_hole_rule_not_found}
    end
  end
end
