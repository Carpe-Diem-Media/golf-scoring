defmodule GolfScoring.Scoring.Services.StandardLeaderboardTest do
  use ExUnit.Case, async: true

  alias GolfScoring.Scoring.Services.{Leaderboard, LoadStandardSideHoles}

  @track %{
    track_type: :standard_better_ball,
    configuration_state: :locked,
    aggregation_policy_identifier: "standard_better_ball_v1",
    tie_break_policy_identifier: "standard_countback_v1"
  }
  @mapping Map.new(1..18, &{"#{&1}", &1})

  test "ranks partial totals, shares places and counts recorded zero" do
    sides = [side("c", [1]), side("b", [2, 0]), side("a", [2])]
    assert {:ok, [a, b, c]} = project(sides)

    assert Enum.map([a, b, c], &{&1.side_id, &1.subtotal, &1.holes_completed, &1.position}) ==
             [{"a", 2, 1, 1}, {"b", 2, 2, 1}, {"c", 1, 1, 3}]

    assert b.display_status == :provisional
  end

  test "withholds excluded, zero-progress and non-computable sides but retains review position" do
    review = side("review", [1], :review_required)
    excluded = side("excluded", [8], :excluded)
    pending = side("pending", [])
    unavailable = side("unavailable", [4]) |> put_hole(1, :not_computable, nil)
    assert {:ok, rows} = project([excluded, pending, unavailable, review])
    assert %{position: 1, display_status: :under_review} = find(rows, "review")
    for id <- ["excluded", "pending", "unavailable"], do: assert(find(rows, id).position == nil)
    assert find(rows, "unavailable").display_status == :unranked
  end

  test "derives neutral status from each lifecycle state and progress" do
    for state <- [:provisional, :ready_to_finalize, :finalized] do
      assert {:ok, [%{display_status: :provisional}]} = project([side("a", [0], state)])
      assert {:ok, [%{display_status: :unranked}]} = project([side("a", [], state)])
    end

    assert {:ok, [%{display_status: :under_review}]} = project([side("a", [], :review_required)])

    assert {:ok, [%{display_status: :under_review}]} =
             project([side("a", [1], :review_required) |> put_hole(1, :not_computable, nil)])

    assert {:ok, [%{display_status: :unranked}]} = project([side("a", [1], :excluded)])
  end

  test "a correction changes order" do
    a = side("a", [1])
    b = side("b", [2])
    assert {:ok, [first | _]} = project([a, b])
    assert first.side_id == "b"
    corrected = put_hole(a, 0, :computed, 3) |> Map.put(:staff_notes, "secret")
    assert {:ok, [first | _]} = project([corrected, b])
    assert first.side_id == "a"
    assert first.subtotal == 3
  end

  test "withdrawal boundary preserves evidence and uses only applicable scores" do
    holes =
      for index <- 0..17 do
        hole_id = "#{index + 1}"

        recorded = fn id, points ->
          %{
            round_entry_id: id,
            round_hole_id: hole_id,
            play_index: index,
            hole_result_id: "result-#{id}-#{index}",
            revision: 2,
            withdrawal_applicability: :applicable,
            ruling_id: nil,
            unresolved_reason: nil,
            status: :recorded,
            points: points
          }
        end

        partner = recorded.("withdrawn", 3)

        partner =
          if index >= 9 do
            %{
              partner
              | withdrawal_applicability: :not_applicable,
                ruling_id: "private-ruling",
                status: :excluded,
                points: nil
            }
          else
            partner
          end

        %{
          play_index: index,
          round_hole_id: hole_id,
          members: [recorded.("remaining", 1), partner]
        }
      end

    assert {:ok, contributions} = LoadStandardSideHoles.project(holes)
    assert Enum.map(contributions, & &1.points) == List.duplicate(3, 9) ++ List.duplicate(1, 9)

    assert %{
             members: [_, %{hole_result_id: "result-withdrawn-8", revision: 2, status: :recorded}]
           } = Enum.at(contributions, 8)

    assert %{
             members: [
               _,
               %{
                 hole_result_id: "result-withdrawn-9",
                 revision: 2,
                 status: :excluded,
                 ruling_id: "private-ruling"
               }
             ]
           } = Enum.at(contributions, 9)

    side = %{side_id: "a", side_result: %{state: :provisional}, holes: contributions}
    assert {:ok, [row]} = project([side])
    assert %{subtotal: 36, holes_completed: 18, position: 1} = row
    refute inspect(row) =~ "private-ruling"
    refute inspect(row) =~ "result-withdrawn"
    refute inspect(row) =~ "members"
  end

  test "complete ties use physical countback regardless of shotgun rotation" do
    front = List.duplicate(1, 9) ++ List.duplicate(0, 9)
    back = List.duplicate(0, 9) ++ List.duplicate(1, 9)
    a = side("a", front)
    b = side("b", back) |> rotate(5)
    assert {:ok, [winner, second]} = project([a, b])
    assert {winner.side_id, winner.position, second.side_id, second.position} == {"b", 1, "a", 2}
  end

  test "mixed complete and incomplete equal totals share place without countback" do
    complete = side("complete", [2 | List.duplicate(0, 17)])
    partial = side("partial", [2])
    assert {:ok, rows} = project([complete, partial, side("third", [1])])
    assert Enum.map(rows, & &1.position) == [1, 1, 3]
  end

  test "complete ties with identical countback keys share positions" do
    assert {:ok, rows} =
             project([
               side("a", List.duplicate(1, 18)),
               side("b", List.duplicate(1, 18)),
               side("c", [1])
             ])

    assert Enum.map(rows, & &1.position) == [1, 1, 3]
  end

  test "rejects missing result, duplicate ids, malformed evidence, policy and mapping" do
    good = side("a", [1])

    for sides <- [
          [Map.delete(good, :side_result)],
          [good, good],
          [put_hole(good, 0, :pending, 0)],
          [Map.put(good, :holes, [])]
        ] do
      assert {:error, :inconsistent_evidence} = project(sides)
    end

    for mapping <- [
          Map.delete(@mapping, "1"),
          Map.put(@mapping, "1", 2),
          Map.put(@mapping, "1", 19)
        ] do
      assert {:error, :inconsistent_evidence} = Leaderboard.project(@track, [good], mapping)
    end

    for track <- [
          Map.put(@track, :configuration_state, :draft),
          Map.put(@track, :tie_break_policy_identifier, "other"),
          %{}
        ] do
      assert {:error, :inconsistent_evidence} = Leaderboard.project(track, [good], @mapping)
    end
  end

  test "output allowlists fields and omits contributor and private evidence" do
    side = side("a", [1]) |> Map.put(:contact, "private-contact")

    side =
      update_in(side.holes, fn [hole | rest] ->
        [
          Map.merge(hole, %{members: [%{audit: "private-audit"}], mystery: "private-mystery"})
          | rest
        ]
      end)

    assert {:ok, [row]} = project([side])

    assert Map.keys(row) |> Enum.sort() ==
             Enum.sort([
               :side_id,
               :subtotal,
               :holes_completed,
               :display_status,
               :position
             ])

    refute inspect(row) =~ "private-"
  end

  defp project(sides), do: Leaderboard.project(@track, sides, @mapping)
  defp find(rows, id), do: Enum.find(rows, &(&1.side_id == id))

  defp side(id, points, state \\ :provisional) do
    holes =
      for n <- 1..18 do
        point = Enum.at(points, n - 1)

        %{
          play_index: n - 1,
          round_hole_id: "#{n}",
          status: if(is_nil(point), do: :pending, else: :computed),
          points: point
        }
      end

    %{side_id: id, side_result: %{state: state}, holes: holes}
  end

  defp put_hole(side, index, status, points),
    do:
      update_in(
        side.holes,
        &List.update_at(&1, index, fn hole -> %{hole | status: status, points: points} end)
      )

  defp rotate(side, amount) do
    holes = Enum.drop(side.holes, amount) ++ Enum.take(side.holes, amount)
    %{side | holes: Enum.with_index(holes, fn hole, index -> %{hole | play_index: index} end)}
  end
end
