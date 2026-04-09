using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;

namespace PlatformCharacterController
{
    [RequireComponent(typeof(MovementCharacterController))]
    public class PlayerInput : Inputs
    {
        [Header("Joystick References")]
        public Joystick movementJoystick;

        [Header("UI Buttons")]
        public Button jumpButton;
        public Button parachuteButton;

        private bool _jumpButtonPressed = false;
        private bool _parachuteButtonPressed = false;

        private void Start()
        {
            if (jumpButton != null)
                jumpButton.onClick.AddListener(() => _jumpButtonPressed = true);

         

            if (parachuteButton != null)
                parachuteButton.onClick.AddListener(() => _parachuteButtonPressed = true);
        }

        private void LateUpdate()
        {
            _jumpButtonPressed = false;
            _parachuteButtonPressed = false;
        }

        public override float GetHorizontal()
        {
            float keyboardInput = Input.GetAxis("Horizontal");
            float joystickInput = movementJoystick != null ? movementJoystick.Horizontal : 0f;
            return Mathf.Clamp(keyboardInput + joystickInput, -1f, 1f);
        }

        public override float GetVertical()
        {
            float keyboardInput = Input.GetAxis("Vertical");
            float joystickInput = movementJoystick != null ? movementJoystick.Vertical : 0f;
            return Mathf.Clamp(keyboardInput + joystickInput, -1f, 1f);
        }

        public override bool Jump()
        {
            return Input.GetKeyDown(KeyCode.Space) || _jumpButtonPressed;
        }

        public override bool Dash()
        {
            return Input.GetKeyDown(KeyCode.F);
        }

        public override bool JetPack()
        {
            return Input.GetKey(KeyCode.X);
        }

        public override bool Parachute()
        {
            return Input.GetKeyDown(KeyCode.R) || _parachuteButtonPressed;
        }

        public override bool DropCarryItem()
        {
            return Input.GetKeyDown(KeyCode.K);
        }
    }
}