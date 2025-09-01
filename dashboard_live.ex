defmodule FullstackChallengeWeb.DashboardLive do
  use FullstackChallengeWeb, :live_view
  alias FullstackChallenge.FlyMetrics

  require Logger

  def mount(_params, session, socket) do
    fly_token = get_token_from_session(session)
    
    env_token = FullstackChallenge.EnvConfig.get_fly_token()
    is_env_token = env_token && fly_token && env_token == fly_token

    if fly_token do
      {:ok,
       socket
       |> assign(:fly_token, fly_token)
       |> assign(:is_env_token, is_env_token)
       |> assign(:apps, [])
       |> assign(:loading, true)
       |> assign(:error, nil)
       |> assign(:show_launch_modal, false)
       |> assign(:show_destroy_modal, false)
       |> assign(:destroy_app, nil)
       |> assign(:launch_form, to_form(%{"name" => ""}, as: :launch))
       |> load_apps()}
    else
      {:ok, push_navigate(socket, to: ~p"/auth")}
    end
  end

  def handle_event("load_apps", _, socket) do
    {:noreply, socket |> assign(:loading, true) |> load_apps()}
  end

  def handle_event("show_launch_modal", _, socket) do
    {:noreply,
     socket
     |> assign(:show_launch_modal, true)
     |> assign(:launch_form, to_form(%{"name" => ""}, as: :launch))}
  end

  def handle_event("hide_launch_modal", _, socket) do
    {:noreply, assign(socket, :show_launch_modal, false)}
  end

  def handle_event("validate_launch", %{"launch" => params}, socket) do
    form = to_form(params, as: :launch)
    {:noreply, assign(socket, :launch_form, form)}
  end

  def handle_event("launch_app", %{"launch" => %{"name" => name}}, socket) do
    case launch_app(socket.assigns.fly_token, name) do
      {:ok, _result} ->
        {:noreply,
         socket
         |> assign(:show_launch_modal, false)
         |> put_flash(:info, "App '#{name}' launched successfully!")
         |> load_apps()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to launch app: #{reason}")}
    end
  end

  def handle_event("show_destroy_modal", %{"app" => app_name}, socket) do
    {:noreply,
     socket
     |> assign(:show_destroy_modal, true)
     |> assign(:destroy_app, app_name)}
  end

  def handle_event("hide_destroy_modal", _, socket) do
    {:noreply,
     socket
     |> assign(:show_destroy_modal, false)
     |> assign(:destroy_app, nil)}
  end


  def handle_event("destroy_app", _, socket) do
    app_name = socket.assigns.destroy_app
    Logger.info("Starting destroy for app: #{app_name}")

    case destroy_app(socket.assigns.fly_token, app_name) do
      {:ok, _result} ->
        Logger.info("App #{app_name} destroyed successfully")

        {:noreply,
         socket
         |> assign(:show_destroy_modal, false)
         |> assign(:destroy_app, nil)
         |> put_flash(:info, "App '#{app_name}' destroyed successfully!")
         |> load_apps()}

      {:error, reason} ->
        Logger.warning("Failed to destroy app #{app_name}: #{reason}")

        {:noreply,
         socket
         |> assign(:show_destroy_modal, false)
         |> assign(:destroy_app, nil)
         |> put_flash(:error, "Failed to destroy app: #{reason}")}
    end
  end


defp load_apps(socket) do
  case list_apps(socket.assigns.fly_token) do
    {:ok, apps} ->
      app_metrics =
        apps
        |> Enum.map(fn app ->
          {app.name, FlyMetrics.fetch_for_app(app.name)}
        end)
        |> Enum.into(%{})

      socket
      |> assign(:apps, apps)
      |> assign(:app_metrics, app_metrics)
      |> assign(:loading, false)
      |> assign(:error, nil)
    {:error, reason} ->
      socket
      |> assign(:loading, false)
      |> assign(:error, "Failed to load apps: #{reason}")
  end
end


  defp list_apps(token) do
    if not valid_token_format?(token) do
      Logger.warning("Invalid token format: #{String.slice(token, 0, 8)}...")
      {:error, "Invalid token format"}
    end

    headers = [{"Authorization", "Bearer #{token}"}]

    Logger.info("Calling Fly.io GraphQL API to list apps...")

    case Req.post("https://api.fly.io/graphql",
           headers: headers,
           form: [query: "{ apps { nodes { id name status organization { slug } createdAt } } }"]
         ) do
      {:ok, %{status: 200, body: body}} ->
        Logger.info("Fly.io API Response: #{inspect(body)}")
        apps = parse_apps_response(body)
        Logger.info("Parsed apps: #{inspect(apps)}")
        {:ok, apps}

      {:ok, %{status: 401}} ->
        Logger.warning("Fly.io API returned 401 Unauthorized")
        {:error, "Invalid token"}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Fly.io API returned status #{status} with body: #{inspect(body)}")
        {:error, "API error (#{status})"}

      {:error, reason} ->
        Logger.error("Network error calling Fly.io API: #{inspect(reason)}")
        {:error, "Network error"}
    end
  end

  defp launch_app(token, name) do
    Logger.info("Attempting to launch app: #{name}")

    case get_user_organization(token) do
      {:ok, org_id} ->
        case create_app(token, name, org_id) do
          {:ok, _app_data} ->
            case allocate_ip_addresses(token, name) do
              {:ok, _ip_data} ->
                case deploy_nginx_app(token, name) do
                  {:ok, _machine_data} ->
                    Logger.info("Successfully launched app: #{name}")
                    {:ok, %{}}
                  
                  {:error, reason} ->
                    Logger.warning("App created but deployment failed: #{reason}")
                    {:error, "App created but deployment failed: #{reason}"}
                end
              
              {:error, reason} ->
                Logger.warning("App created but IP allocation failed: #{reason}")
                {:error, "App created but IP allocation failed: #{reason}"}
            end
          
          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, "Failed to get organization: #{reason}"}
    end
  end

  defp create_app(token, name, org_id) do
    headers = [{"Authorization", "Bearer #{token}"}, {"Content-Type", "application/json"}]
    
    mutation = %{
      query: """
        mutation($input: CreateAppInput!) {
          createApp(input: $input) {
            app {
              id
              name
            }
          }
        }
      """,
      variables: %{
        input: %{
          name: name,
          organizationId: org_id
        }
      }
    }

    case Req.post("https://api.fly.io/graphql",
           headers: headers,
           body: Jason.encode!(mutation)
         ) do
      {:ok, %{status: 200, body: %{"data" => %{"createApp" => data}}}} when not is_nil(data) ->
        Logger.info("Created app: #{inspect(data)}")
        {:ok, data}

      {:ok, %{status: 200, body: %{"errors" => errors}}} ->
        Logger.warning("GraphQL errors creating app: #{inspect(errors)}")
        error_msg = get_in(errors, [Access.at(0), "message"]) || "GraphQL error"
        {:error, error_msg}

      {:ok, %{status: 401}} ->
        {:error, "Invalid token"}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Fly.io API returned status #{status} with body: #{inspect(body)}")
        {:error, "API error (#{status})"}

      {:error, reason} ->
        Logger.error("Network error creating app: #{inspect(reason)}")
        {:error, "Network error"}
    end
  end

  defp allocate_ip_addresses(token, app_name) do
    headers = [{"Authorization", "Bearer #{token}"}, {"Content-Type", "application/json"}]
    
    ipv4_mutation = %{
      query: """
        mutation($input: AllocateIPAddressInput!) {
          allocateIpAddress(input: $input) {
            ipAddress {
              id
              address
              type
            }
          }
        }
      """,
      variables: %{
        input: %{
          appId: app_name,
          type: "v4"
        }
      }
    }

    case Req.post("https://api.fly.io/graphql",
           headers: headers,
           body: Jason.encode!(ipv4_mutation)
         ) do
      {:ok, %{status: 200, body: %{"data" => %{"allocateIpAddress" => ipv4_data}}}} when not is_nil(ipv4_data) ->
        Logger.info("Allocated IPv4 for app #{app_name}: #{inspect(ipv4_data)}")
        
        allocate_ipv6(token, app_name)
        {:ok, ipv4_data}

      {:ok, %{status: 200, body: %{"errors" => errors}}} ->
        Logger.warning("GraphQL errors allocating IP: #{inspect(errors)}")
        error_msg = get_in(errors, [Access.at(0), "message"]) || "IP allocation error"
        {:error, error_msg}

      {:ok, %{status: 401}} ->
        {:error, "Invalid token"}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("IP allocation API returned status #{status} with body: #{inspect(body)}")
        {:error, "IP allocation failed (#{status})"}

      {:error, reason} ->
        Logger.error("Network error allocating IP: #{inspect(reason)}")
        {:error, "Network error"}
    end
  end

  defp allocate_ipv6(token, app_name) do
    headers = [{"Authorization", "Bearer #{token}"}, {"Content-Type", "application/json"}]
    
    ipv6_mutation = %{
      query: """
        mutation($input: AllocateIPAddressInput!) {
          allocateIpAddress(input: $input) {
            ipAddress {
              id
              address
              type
            }
          }
        }
      """,
      variables: %{
        input: %{
          appId: app_name,
          type: "v6"
        }
      }
    }

    case Req.post("https://api.fly.io/graphql",
           headers: headers,
           body: Jason.encode!(ipv6_mutation)
         ) do
      {:ok, %{status: 200, body: %{"data" => %{"allocateIpAddress" => ipv6_data}}}} when not is_nil(ipv6_data) ->
        Logger.info("Allocated IPv6 for app #{app_name}: #{inspect(ipv6_data)}")
        {:ok, ipv6_data}

      {:ok, %{status: 200, body: %{"errors" => _errors}}} ->
        Logger.info("IPv6 allocation failed for app #{app_name}, continuing with IPv4 only")
        {:ok, nil}

      _ ->
        Logger.info("IPv6 allocation failed for app #{app_name}, continuing with IPv4 only")
        {:ok, nil}
    end
  end

  defp deploy_nginx_app(token, app_name) do
    headers = [{"Authorization", "Bearer #{token}"}, {"Content-Type", "application/json"}]
    
    template = FullstackChallenge.AppTemplates.nginx_app_template(app_name)
    
    machine_config = %{
      config: %{
        image: "nginx:alpine",
        env: %{},
        services: [
          %{
            ports: [
              %{
                port: 80,
                handlers: ["http"]
              },
              %{
                port: 443,
                handlers: ["tls", "http"]
              }
            ],
            protocol: "tcp",
            internal_port: 8080
          }
        ],
        files: [
          %{
            guest_path: "/usr/share/nginx/html/index.html",
            raw_value: Base.encode64(template.index_html)
          },
          %{
            guest_path: "/etc/nginx/nginx.conf", 
            raw_value: Base.encode64(template.nginx_conf)
          }
        ],
        guest: %{
          cpu_kind: "shared",
          cpus: 1,
          memory_mb: 256
        }
      }
    }

    case Req.post("https://api.machines.dev/v1/apps/#{app_name}/machines",
           headers: headers,
           body: Jason.encode!(machine_config)
         ) do
      {:ok, %{status: status, body: body}} when status in [200, 201] ->
        Logger.info("Deployed machine for app #{app_name}: #{inspect(body)}")
        {:ok, body}

      {:ok, %{status: 401}} ->
        {:error, "Invalid token"}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Machines API returned status #{status} with body: #{inspect(body)}")
        {:error, "Deployment failed (#{status})"}

      {:error, reason} ->
        Logger.error("Network error deploying app: #{inspect(reason)}")
        {:error, "Network error"}
    end
  end

  defp get_user_organization(token) do
    headers = [{"Authorization", "Bearer #{token}"}, {"Content-Type", "application/json"}]
    
    query = %{
      query: """
        {
          viewer {
            organizations {
              nodes {
                id
                slug
              }
            }
          }
        }
      """
    }

    case Req.post("https://api.fly.io/graphql",
           headers: headers,
           body: Jason.encode!(query)
         ) do
      {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"organizations" => %{"nodes" => [_ | _] = orgs}}}}}} ->
        org_id = get_in(orgs, [Access.at(0), "id"])
        {:ok, org_id}

      {:ok, %{status: 200, body: %{"errors" => errors}}} ->
        Logger.warning("GraphQL errors getting organization: #{inspect(errors)}")
        {:error, "Failed to get organization"}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Failed to get organization, status #{status}: #{inspect(body)}")
        {:error, "API error"}

      {:error, reason} ->
        Logger.error("Network error getting organization: #{inspect(reason)}")
        {:error, "Network error"}
    end
  end

  defp destroy_app(token, app_name) do
    headers = [{"Authorization", "Bearer #{token}"}, {"Content-Type", "application/json"}]

    Logger.info(
      "Attempting to destroy app: #{app_name} with token: #{String.slice(token, 0, 8)}..."
    )

    mutation = %{
      query: """
        mutation($appId: ID!) {
          deleteApp(appId: $appId) {
            organization {
              id
            }
          }
        }
      """,
      variables: %{
        appId: app_name
      }
    }

    case Req.post("https://api.fly.io/graphql",
           headers: headers,
           body: Jason.encode!(mutation)
         ) do
      {:ok, %{status: 200, body: %{"data" => %{"deleteApp" => data}}}} when not is_nil(data) ->
        Logger.info("Destroy app API response (data): #{inspect(data)}")
        {:ok, %{}}

      {:ok, %{status: 200, body: %{"errors" => errors}}} ->
        Logger.warning("GraphQL errors in destroy app: #{inspect(errors)}")
        error_msg = get_in(errors, [Access.at(0), "message"]) || "GraphQL error"
        {:error, error_msg}

      {:ok, %{status: 401, body: body}} ->
        Logger.warning("Destroy app unauthorized: #{inspect(body)}")
        {:error, "Invalid token"}

      {:ok, %{status: 404, body: body}} ->
        Logger.warning("Destroy app not found: #{inspect(body)}")
        {:error, "App not found"}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Fly.io API returned status #{status} with body: #{inspect(body)}")
        {:error, "API error (#{status})"}

      {:error, reason} ->
        Logger.error("Network error destroying app: #{inspect(reason)}")
        {:error, "Network error"}
    end
  end

  defp parse_apps_response(%{"errors" => errors}) when is_list(errors) do
    Logger.warning("GraphQL errors in parse_apps_response: #{inspect(errors)}")
    []
  end

  defp parse_apps_response(%{"data" => %{"apps" => %{"nodes" => apps}}}) when is_list(apps) do
    Enum.map(apps, fn app ->
      %{
        name: Map.get(app, "name", "unknown"),
        status: Map.get(app, "status", "running"),
        region: Map.get(app["organization"], "slug", "unknown"),
        created_at: Map.get(app, "createdAt", "unknown")
      }
    end)
  end

  defp valid_token_format?(token) when is_binary(token) do
    String.starts_with?(token, "FlyV1") and String.length(token) > 50
  end

  defp valid_token_format?(_), do: false
  
  defp get_token_from_session(session) do
    case Map.get(session, "auth_token_ref") do
      ref when is_binary(ref) ->
        session_id = Map.get(session, "session_id") || generate_session_id()
        case FullstackChallenge.TokenStore.get_token(ref, session_id) do
          {:ok, token} -> 
            token
          {:error, reason} -> 
            Logger.debug("Token retrieval failed: #{reason}")
            try_fallback_methods(session)
        end
      
      nil ->
        try_fallback_methods(session)
    end
  end
  
  defp try_fallback_methods(session) do
    case FullstackChallenge.TokenSecurity.decrypt_token(Map.get(session, "encrypted_fly_token")) do
      {:ok, token} -> 
        token
      _ -> 
        case Map.get(session, "auth_token") do
          token when is_binary(token) -> 
            token
          _ -> 
            FullstackChallenge.EnvConfig.get_fly_token()
        end
    end
  end
  
  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
