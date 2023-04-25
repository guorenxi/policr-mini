defmodule PolicrMiniBot.Worker.ValidationTerminator do
  @moduledoc """
  负责终止验证（处理超时）的 Worker。
  """

  use PolicrMiniBot.Worker

  alias PolicrMini.{
    Logger,
    Repo,
    Chats,
    VerificationBusiness,
    StatisticBusiness,
    OperationBusiness
  }

  alias PolicrMini.Schema.Verification
  alias PolicrMini.Chats.Scheme
  alias PolicrMiniBot.{Cleaner, CallVerificationPlug}

  import PolicrMiniBot.Helper

  @queue_name :validation_terminator
  @max_concurrency 9999

  @impl true
  def init_queue do
    :ok = Honeydew.start_queue(@queue_name)
    :ok = Honeydew.start_workers(@queue_name, __MODULE__, num: @max_concurrency)
  end

  @impl true
  def job_key(:terminate = task, veri) when is_struct(veri, Verification) do
    %{chat_id: chat_id, target_user_id: user_id} = veri

    job_key(task, [chat_id, user_id])
  end

  @impl true
  def job_key(:terminate, [chat_id, user_id]) do
    "terminate-#{chat_id}-#{user_id}"
  end

  # TODO: 自定义失败模式，当失败发生时更新验证状态并移除任务缓存。
  @doc """
  终止超时验证。
  """
  @spec terminate(Verification.t(), Scheme.t(), integer) :: :ok
  def terminate(veri, scheme, waiting_secs)
      when is_struct(veri, Verification) and is_struct(scheme, Scheme) do
    %{chat_id: chat_id, target_user_id: user_id, target_user_name: user_name} = veri
    user = %{id: user_id, fullname: user_name}

    msg =
      "[#{veri.id}] Validation validity time is about to end, start processing timeout, details: #{inspect(chat_id: chat_id, user_id: user_id)}"

    Logger.debug(msg)

    # 读取最新的验证数据，因为用户参与验证可能会同时发生
    last_veri = Repo.reload(veri)
    # 为等待状态才实施操作
    if last_veri.status == :waiting do
      # 自增统计数据（超时）
      StatisticBusiness.increment_one(
        veri.chat_id,
        veri.target_user_language_code,
        :timeout
      )

      killing_method = scheme.timeout_killing_method || default!(:tkmethod)
      delay_unban_secs = scheme.delay_unban_secs || default!(:delay_unban_secs)

      # 添加操作记录
      create_operation(last_veri, killing_method, :system)

      # 计数器自增（超时总数）
      PolicrMini.Counter.increment(:verification_timeout_total)
      # 更新状态为超时
      VerificationBusiness.update(last_veri, %{status: :timeout})
      # 击杀用户（原因为超时）
      CallVerificationPlug.kill(chat_id, user, :timeout, killing_method, delay_unban_secs)

      # 如果还存在多条验证，更新入口消息
      waiting_count = VerificationBusiness.get_waiting_count(chat_id)

      if waiting_count == 0 do
        # 已经没有剩余验证，直接删除上一个入口消息
        Cleaner.delete_latest_verification_message(chat_id)
      else
        # 如果还存在多条验证，更新入口消息
        CallVerificationPlug.update_unity_message(
          chat_id,
          waiting_count,
          scheme,
          waiting_secs
        )
      end
    else
      Logger.debug("[#{veri.id}] Validation ends prematurely, ignoring timeout handling")
    end

    Logger.debug("[#{veri.id}] Timeout processing has ended")

    # 从缓存中删除任务
    JobCacher.delete_job(job_key(:terminate, veri))

    :ok
  end

  @type operation_status :: :manual_ban | :manual_kick

  @doc """
  手动终止验证。
  """
  @spec manual_terminate(Verification.t(), operation_status) :: :ok
  def manual_terminate(veri, status) when status in [:manual_ban, :manual_kick] do
    %{chat_id: chat_id, target_user_id: user_id, target_user_name: user_name} = veri
    user = %{id: user_id, fullname: user_name}

    msg =
      "[#{veri.id}] Manual termination verification started, details: #{inspect(chat_id: chat_id, user_id: user_id)}"

    Logger.debug(msg)

    # 为等待状态才实施操作
    if veri.status == :waiting do
      # 终止超时处理任务
      :ok = PolicrMiniBot.Worker.cancel_terminate_validation_job(chat_id, user_id)

      {:ok, scheme} = Chats.fetch_scheme(chat_id)

      msg =
        "[#{veri.id}] Validation was manually terminated by administrator, details: #{inspect(chat_id: chat_id, user_id: user_id)}"

      Logger.debug(msg)

      kmeth = if status == :manual_ban, do: :ban, else: :kick
      delay_unban_secs = scheme.delay_unban_secs || default!(:delay_unban_secs)

      # 添加操作记录
      create_operation(veri, kmeth, :admin)

      # 添加统计（其它）
      StatisticBusiness.increment_one(
        veri.chat_id,
        veri.target_user_language_code,
        :other
      )

      # 更新状态为超时
      VerificationBusiness.update(veri, %{status: status})
      # 击杀用户（原因即状态）
      CallVerificationPlug.kill(chat_id, user, status, kmeth, delay_unban_secs)

      # 如果还存在多条验证，更新入口消息
      waiting_count = VerificationBusiness.get_waiting_count(chat_id)

      if waiting_count == 0 do
        # 已经没有剩余验证，直接删除上一个入口消息
        Cleaner.delete_latest_verification_message(chat_id)
      else
        # 如果还存在多条验证，更新入口消息
        CallVerificationPlug.update_unity_message(
          chat_id,
          waiting_count,
          scheme,
          scheme.seconds
        )
      end

      Logger.debug("[#{veri.id}] Manual termination verification has ended")

      # 从缓存中删除任务
      JobCacher.delete_job(job_key(:terminate, veri))
    else
      msg = "[#{veri.id}] Validation is not in progress and does not need to be terminated"

      Logger.debug(msg)
    end

    :ok
  end

  # 添加操作记录（系统）
  defp create_operation(verification, killing_method, role) when role in [:system, :admin] do
    action = if killing_method == :ban, do: :ban, else: :kick

    params = %{
      verification_id: verification.id,
      action: action,
      role: role
    }

    case OperationBusiness.create(params) do
      {:ok, _} = r ->
        r

      e ->
        Logger.unitized_error("Operation creation", e)

        e
    end
  end

  @spec async_terminate(Verification.t(), Scheme.t(), integer) :: Honeydew.Job.t()
  def async_terminate(veri, scheme, waiting_secs) do
    %{chat_id: chat_id, target_user_id: user_id} = veri
    job_key = job_key(:terminate, veri)

    if job = JobCacher.get_job(job_key) do
      # 已存在
      msg =
        "[#{veri.id}] Termination verification task already exists, details: #{inspect(chat_id: chat_id, user_id: user_id)}"

      Logger.debug(msg)

      job
    else
      fun = {:terminate, [veri, scheme, waiting_secs]}
      job = Honeydew.async(fun, @queue_name, delay_secs: waiting_secs)

      JobCacher.add_job(job_key, job)

      msg =
        "Created async termination task, details: #{inspect(chat_id: chat_id, user_id: user_id, waiting_secs: waiting_secs)}"

      Logger.debug(msg)

      job
    end
  end
end
