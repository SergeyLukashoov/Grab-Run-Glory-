using UnityEngine;
using System.Collections;
using PlatformCharacterController;

public class CameraControl : MonoBehaviour
{
    public Transform Target;
    public float Distance = 35F;
    private float SpeedX = 240;
    private float SpeedY = 120;
    private float MinLimitY = 5;
    private float MaxLimitY = 180;

    public float RotateX = 0.0F;
    public float RotateY = 30.0F;

    private float MaxDistance = 100;
    private float MinDistance = 15F;
    private float ZoomSpeed = 2F;

    public bool isNeedDamping = false;
    public float Damping = 10F;

    // Параметры для тач-управления
    public bool enableTouchControls = true;
    public float touchRotationSensitivity = 0.5f;
    public float touchZoomSensitivity = 0.01f;
    public float pinchZoomSensitivity = 0.5f;

    private Quaternion mRotation = Quaternion.identity;
    private Vector2?[] oldTouchPositions = null;

    // Ссылка на MovementCharacterController

    void Start()
    {

        mRotation = Quaternion.Euler(RotateY, RotateX, 0);

        if (isNeedDamping)
        {
            transform.rotation = Quaternion.Lerp(transform.rotation, mRotation, Time.deltaTime * Damping);
        }
        else
        {
            transform.rotation = mRotation;
        }

        Vector3 mPosition = mRotation * new Vector3(0.0F, 0.0F, -Distance) + Target.position;

        if (isNeedDamping)
        {
            transform.position = Vector3.Lerp(transform.position, mPosition, Time.deltaTime * Damping);
        }
        else
        {
            transform.position = mPosition;
        }
    }

    void LateUpdate()
    {
        if (Target == null) return;

        // Определяем платформу
        //if (Application.isMobilePlatform && enableTouchControls)
        //{
        //    HandleTouchInput();
        //}
        //else
        //{
        //    HandleMouseInput();
        //}

        // Применяем изменения
        mRotation = Quaternion.Euler(RotateY, RotateX, 0);

        if (isNeedDamping)
        {
            transform.rotation = Quaternion.Lerp(transform.rotation, mRotation, Time.deltaTime * Damping);
        }
        else
        {
            transform.rotation = mRotation;
        }

        Vector3 mPosition = mRotation * new Vector3(0.0F, 0.0F, -Distance) + Target.position;

        if (isNeedDamping)
        {
            transform.position = Vector3.Lerp(transform.position, mPosition, Time.deltaTime * Damping);
        }
        else
        {
            transform.position = mPosition;
        }
    }

    //private void HandleMouseInput()
    //{
    //    // Мышь: зум (только если можно приближать)
    //    if (CanZoom())
    //    {
    //        Distance -= Input.GetAxis("Mouse ScrollWheel") * ZoomSpeed;
    //        Distance = Mathf.Clamp(Distance, MinDistance, MaxDistance);
    //    }
    //}

    //private void HandleTouchInput()
    //{
    //    // Два касания: пинч-зум (только если можно приближать)
    //    if (Input.touchCount == 2 && CanZoom())
    //    {
    //        Touch touch1 = Input.GetTouch(0);
    //        Touch touch2 = Input.GetTouch(1);

    //        Vector2 touch1PrevPos = touch1.position - touch1.deltaPosition;
    //        Vector2 touch2PrevPos = touch2.position - touch2.deltaPosition;

    //        float prevTouchDeltaMag = (touch1PrevPos - touch2PrevPos).magnitude;
    //        float touchDeltaMag = (touch1.position - touch2.position).magnitude;

    //        float deltaMagnitudeDiff = prevTouchDeltaMag - touchDeltaMag;

    //        Distance += deltaMagnitudeDiff * pinchZoomSensitivity;
    //        Distance = Mathf.Clamp(Distance, MinDistance, MaxDistance);
    //    }
    //}

    //// Проверка, можно ли приближать камеру
    //private bool CanZoom()
    //{
    //    // Если playerMovement не найден или isMove = false, то можно приближать
    //    return playerMovement == null || !playerMovement.isMove;
    //}

    private float ClampAngle(float angle, float min, float max)
    {
        if (angle < -360) angle += 360;
        if (angle > 360) angle -= 360;
        return Mathf.Clamp(angle, min, max);
    }
}