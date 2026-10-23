import { cn } from "../lib/utils";
import { forwardRef, useRef, type ComponentProps, type ReactNode } from "react";
import { Button as ShadcnButton, type ButtonProps } from "./ui/button";
import { Input } from "./ui/input";
import { Dialog, DialogContent, DialogTitle } from "./ui/dialog";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "./ui/tooltip";

// Keep existing layout classes while sharing shadcn's focus, disabled and variant rules.
export const Button = forwardRef<HTMLButtonElement, ButtonProps & { tooltipSide?: "top" | "right" | "bottom" | "left" }>(function Button({ title, tooltipSide = "top", className = "", variant, size, ...props }, ref) {
  const primary = /(?:^|\s)(?:primary|primary-button|new-note-button)(?:\s|$)/.test(className);
  const outline = /(?:^|\s)secondary(?:\s|$)/.test(className);
  const button = <ShadcnButton {...props} ref={ref} className={className} variant={variant ?? (primary ? "default" : outline ? "outline" : "ghost")} size={size ?? (/icon-button/.test(className) ? "icon" : "sm")} />;
  return title ? <TooltipProvider delayDuration={350}><Tooltip><TooltipTrigger asChild>{props.disabled ? <span tabIndex={0} aria-label={props["aria-label"]} className="inline-flex">{button}</span> : button}</TooltipTrigger><TooltipContent className={tooltipSide === "right" ? "console-nav-tooltip" : undefined} side={tooltipSide} sideOffset={10}>{title}</TooltipContent></Tooltip></TooltipProvider> : button;
});
export { Input };

export function Modal({ title, onClose, children, className = "", ...props }: Omit<ComponentProps<typeof DialogContent>, "title"> & { title: string; onClose: () => void; children: ReactNode }) {
  const previousFocus = useRef(document.activeElement);
  return <Dialog open onOpenChange={open => { if (!open) onClose(); }}><DialogContent {...props} data-vessel-dialog showCloseButton={false} className={cn("w-[calc(100vw-32px)] max-w-[560px]", className)} aria-describedby={undefined} onCloseAutoFocus={event => { event.preventDefault(); const target = previousFocus.current; if (target instanceof HTMLElement && target.isConnected) target.focus(); }}><DialogTitle className="sr-only">{title}</DialogTitle>{children}</DialogContent></Dialog>;
}
