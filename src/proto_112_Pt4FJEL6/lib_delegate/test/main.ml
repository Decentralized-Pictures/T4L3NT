let () =
  Alcotest_lwt.run
    "delegate_112_Pt4FJEL6"
    [("client_baking_forge", Test_client_baking_forge.tests)]
  |> Lwt_main.run
