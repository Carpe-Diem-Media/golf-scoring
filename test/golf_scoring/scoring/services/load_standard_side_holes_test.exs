defmodule GolfScoring.Scoring.Services.LoadStandardSideHolesTest do
  use ExUnit.Case, async: true

  alias GolfScoring.Scoring.Services.LoadStandardSideHoles

  test "derives BEST while preserving source evidence and playing order" do
    holes = schedule([member("a", :recorded, 3), member("b", :recorded, 0)])
    assert {:ok, projected} = LoadStandardSideHoles.project(holes)
    assert Enum.map(projected, & &1.play_index) == Enum.to_list(0..17)
    assert Enum.map(projected, & &1.round_hole_id) == Enum.map(holes, & &1.round_hole_id)
    assert Enum.all?(projected, &(&1.points == 3 and &1.status == :computed))
    assert hd(projected).members == hd(holes).members
    assert hd(hd(projected).members).revision == 2
    refute inspect(projected) =~ "mystery"
  end

  test "uses the real score for solo and withdrawn partner, including zero" do
    solo = schedule([member("a", :recorded, 0)])
    excluded = schedule([member("a", :recorded, 4), member("b", :excluded, nil)])
    assert {:ok, [%{status: :computed, points: 0} | _]} = LoadStandardSideHoles.project(solo)

    assert {:ok, [%{status: :computed, points: 4, members: [_, partner]} | _]} =
             LoadStandardSideHoles.project(excluded)

    assert partner.ruling_id == "ruling" and partner.hole_result_id != nil
  end

  test "distinguishes incomplete and unavailable contributions from recorded zero" do
    for members <- [
          [member("a", :recorded, 2), member("b", :pending, nil)],
          [member("a", :pending, nil), member("b", :pending, nil)]
        ] do
      assert {:ok, [%{status: :pending, points: nil} | _]} =
               LoadStandardSideHoles.project(schedule(members))
    end

    assert {:ok, [%{status: :not_computable, points: nil} | _]} =
             LoadStandardSideHoles.project(schedule([member("a", :excluded, nil)]))
  end

  test "rejects contradictory, duplicate and malformed evidence" do
    valid = schedule([member("a", :recorded, 2), member("b", :pending, nil)])
    [first | rest] = valid

    for bad <- [
          Map.put(first, :members, [hd(first.members), hd(first.members)]),
          Map.update!(first, :members, fn [a, b] -> [Map.put(a, :points, nil), b] end),
          Map.put(first, :round_hole_id, nil),
          %{}
        ] do
      assert {:error, :inconsistent_evidence} = LoadStandardSideHoles.project([bad | rest])
    end

    assert {:error, :inconsistent_evidence} = LoadStandardSideHoles.project(tl(valid))
  end

  defp schedule(members) do
    for index <- 0..17 do
      hole = "hole-#{rem(index + 17, 18)}"

      %{
        play_index: index,
        round_hole_id: hole,
        members:
          Enum.map(members, fn m ->
            m
            |> Map.put(:play_index, index)
            |> Map.put(:round_hole_id, hole)
            |> Map.update!(:hole_result_id, fn id -> if id, do: "#{id}-#{index}", else: nil end)
          end)
      }
    end
  end

  defp member(id, status, points) do
    %{
      round_entry_id: id,
      status: status,
      points: points,
      hole_result_id: if(status == :pending, do: nil, else: "result-#{id}"),
      revision: if(status == :pending, do: nil, else: 2),
      withdrawal_applicability: if(status == :excluded, do: :not_applicable, else: :applicable),
      ruling_id: if(status == :excluded, do: "ruling", else: nil),
      unresolved_reason: nil
    }
  end
end
